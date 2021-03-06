function Get-EndPoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$connectedServiceName
        )

    $connectedService = Get-VstsInput -Name $connectedServiceName -Require
    $endpoint = Get-VstsEndpoint -Name $connectedService -Require

    $endpoint
}

function Get-AuthHeaderValue {
    param(
        $endpoint
    )

    $username = ""
    $password = [string]$endpoint.auth.parameters.password

    $basicAuth = ("{0}:{1}" -f $username, $password)
    $basicAuth = [System.Text.Encoding]::UTF8.GetBytes($basicAuth)
    $basicAuth = [System.Convert]::ToBase64String($basicAuth)
    ("Basic {0}" -f $basicAuth)
}

function Get-SuspendedEnvironments {
    param(
        $endpoint,
        $releaseDefinitionId,
        [string] $envName
    )

    if([String]::IsNullOrEmpty($envName)) {
        return ""
    }

    $authHeader = Get-AuthHeaderValue $endpoint
    
    $getReleaseEnvsri = "$($endpoint.url)_apis/release/definitions/$releaseDefinitionId"

    $result = Invoke-WebRequest -Method Get -Uri $getReleaseEnvsri -ContentType "application/json" -Headers @{Authorization=$authHeader}
    $envs = (ConvertFrom-Json $result.Content).environments | Select-Object -ExpandProperty Name 

    if (-not $envs.Contains($envName)) {
        Write-Error "Release Definition #$releaseDefinitionId doesn't contain ""$envName"" environment"
    }
    
    $envs = $envs | Where-Object { $_ -ne $envName }

    $skip = """" + [String]::Join(""",""", $envs) + """"
    Write-Host "Environments triger will be changed from automated to manual: "
    Write-Host $skip
    return $skip
}

function Get-RequestedEnvironment {
    param(
        $endpoint,
        $releaseDefinitionId,
        [string] $envName
    )

    if([String]::IsNullOrEmpty($envName)) {
        return ""
    }

    $authHeader = Get-AuthHeaderValue $endpoint
    
    $getReleaseEnvsri = "$($endpoint.url)_apis/release/definitions/$releaseDefinitionId"

    $result = Invoke-WebRequest -Method Get -Uri $getReleaseEnvsri -ContentType "application/json" -Headers @{Authorization=$authHeader}
    $envs = (ConvertFrom-Json $result.Content).environments | Select-Object -ExpandProperty Name 

    if (-not $envs.Contains($envName)) {
        Write-Error "Release Definition #$releaseDefinitionId doesn't contain ""$envName"" environment"
    }
    
    $envs = $envs | Where-Object { $_ -eq $envName }
    $envID = $envs[0].id;
    $skip = """" + [String]::Join(""",""", $envs) + """"
    Write-Host "Environment $envName is $envID "
    
    return $envID
}

function Get-ThisReleaseEnvironmentID {
    param(
        $endpoint,
        [string] $releaseId,
        [string] $envName
    )

    if([String]::IsNullOrEmpty($envName)) {
        return ""
    }

    Write-Debug "the release id to retrieve is $releaseId"
    Write-Debug "looking for environment $envName"
    $authHeader = Get-AuthHeaderValue $endpoint
    
    $getReleaseEnvsri = "$($endpoint.url)_apis/release/releases/{0}?api-version=3.2-preview"

    $url = $getReleaseEnvsri -f $releaseId
    $result = Invoke-WebRequest -Method Get -Uri $url -ContentType "application/json" -Headers @{Authorization=$authHeader}
    $release = $result | ConvertFrom-Json
    Write-Debug "Release is : $release";
    $envs = $release.environments;
    $envcount = $envs.Count
    #$envs = (ConvertFrom-Json $result.Content).environments 
    Write-Debug "found environments in release  : $envcount" 
    #if (-not $envs.Contains($envName)) {
    #    Write-Error "Release Definition #$releaseDefinitionId doesn't contain ""$envName"" environment"
    #}
    
    $envs = $envs | Where-Object { $_.name -eq $envName }
    $envID = $envs[0].id;
    
    Write-Host "Environment $envName is $envID "
    
    return $envID
}


function StartReleaseEnvironmentDeploy($endpoint,[string] $releaseId,[string] $envId) {


    Write-Debug "Starting for $releaseId"
    Write-Debug "env $envId"
    $status = Get-ReleaseEnvironmentStatus -endpoint $endpoint -releaseId $releaseId -envId $envId
    if($status -ieq  "notStarted")
    {
    Write-Host "Calling to set envId $envId to inprogress"

    $authHeader = Get-AuthHeaderValue $endpoint
    
    $getReleaseEnvsri = "$($endpoint.url)_apis/release/releases/{0}/environments/{1}?api-version=3.2-preview"

    $url = $getReleaseEnvsri -f $releaseId, $envId
$body=@"
{
"status": "inprogress"
}
"@

    $result = Invoke-WebRequest -Method Patch -Uri $url -ContentType "application/json" -Headers @{Authorization=$authHeader} -Body $body
    $release = $result | ConvertFrom-Json


    Write-Host "Started deploy in environment $result"
}
else{
    Write-Host "The requested environment appears to already have been started, so did not attempt to restart"
    Write-Host "the environment had a status of $status"
}

    return
}


function Get-ReleaseEnvironmentStatus($endpoint, [string]$releaseId, [string]$envId) {

    $url = ""
    $authHeader = Get-AuthHeaderValue $endpoint
    Write-debug "checking status for Rel $releaseId env $envId"

    $getReleaseEnvsri = "$($endpoint.url)_apis/release/releases/{0}/environments/{1}?api-version=3.2-preview"
    $url = $getReleaseEnvsri -f $releaseId, $envId 
        Write-Debug "calling $url"
        $result = Invoke-WebRequest -Method Get -Uri $url -ContentType "application/json" -Headers @{Authorization=$authHeader}
        $status = (ConvertFrom-Json $result.Content).status

        return $status
}

function ExponentialDelay {
    param(
        $failedAttempts,
        $maxDelayInSeconds = 1024
        )

    # //Attempt 1     0s     0s
    # //Attempt 2     2s     2s
    # //Attempt 3     4s     4s
    # //Attempt 4     8s     8s
    # //Attempt 5     16s    16s
    # //Attempt 6     32s    32s

    # //Attempt 7     64s     1m 4s
    # //Attempt 8     128s    2m 8s
    # //Attempt 9     256s    4m 16s
    # //Attempt 10    512     8m 32s
    # //Attempt 11    1024    17m 4s
    # //Attempt 12    2048    34m 8s

    # //Attempt 13    4096    1h 8m 16s
    # //Attempt 14    8192    2h 16m 32s
    # //Attempt 15    16384   4h 33m 4s

    $delayInSeconds = ((1d / 2d) * ([Math]::Pow(2d, $failedAttempts) - 1d))

    if($maxDelayInSeconds -lt $delayInSeconds){
        $maxDelayInSeconds
    } else {
        $delayInSeconds
    }
}