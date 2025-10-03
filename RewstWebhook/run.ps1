using namespace System.Web

# Input binding data
param($Request)

# Initialize the response object
$Response = @{
    StatusCode = 200
    ContentType = 'application/json'
    Body = @{
        Success = $false
        Output = $null
        Error = $null
    }
}

function Test-JsonCompatibleType {
    param(
        [Parameter(ValueFromPipeline=$true)]
        $InputObject
    )

    # Define JSON-compatible types
    $basicTypes = @([string], [int], [long], [decimal], [double], [boolean], [DateTime])

    if ($null -eq $InputObject) {
        return $true
    }

    # Check basic types
    if ($basicTypes | Where-Object { $InputObject -is $_}) {
        return $true
    }

    # Check arrays and collections
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        foreach ($item in $InputObject) {
            if (-not (Test-JsonCompatibleType $item)) {
                return $false
            }
        }
        return $true
    }

    # Check hashtables and custom objects
    if ($InputObject -is [hashtable] -or $InputObject.PSObject.TypeNames[0] -eq 'System.Management.Automation.PSCustomObject') {
        foreach ($property in $InputObject.PSObject.Properties) {
            if (-not (Test-JsonCompatibleType $property.Value)) {
                return $false
            }
        }
        return $true
    }

    # If none of the above, it's not JSON compatible
    return $false
}

function Convert-ToJsonSafe {
    param(
        [Parameter(ValueFromPipeline=$true)]
        $InputObject,
        [switch]$ThrowOnInvalid
    )

    try {
        if (-not (Test-JsonCompatibleType $InputObject)) {
            $typeName = $InputObject.GetType().FullName
            $errorMsg = "Object of type '$typeName' is not JSON Schema compatible"
            if ($ThrowOnInvalid) {
                throw $errorMsg
            }
            return $errorMsg
        }

        if ($InputObject -is [string]) {
            return $InputObject
        }

        $jsonString = $InputObject | ConvertTo-Json -Compress
        return $jsonString
    }
    catch {
        if ($ThrowOnInvalid) {
            throw
        }
        return $_.Exception.Message
    }
}

try {
    # Get the request body
    $requestBody = $Request.RawBody
    if (-not $requestBody) {
        $requestBody = $Request.Body
    }

    # Convert request body to string if it's a byte array
    if ($requestBody -is [byte[]]) {
        $requestBody = [System.Text.Encoding]::UTF8.GetString($requestBody)
    }

    # Ensure we have a string to work with
    if ($null -eq $requestBody) {
        throw "Request body is empty"
    }

    # Parse the JSON input and store context
    $parsedBody = $requestBody | ConvertFrom-Json

    # Extract the command and context
    if ($parsedBody.command) {
        $scriptContent = [String]$parsedBody.command
        $contextData = $parsedBody.context
    }
    elseif ($parsedBody.Script) {
        $scriptContent = [String]$parsedBody.Script
        $contextData = $parsedBody.context
    }
    else {
        throw "No 'command' or 'Script' property found in request body"
    }

    $supportedGlobals = $null
    if ($parsedBody.supported_globals) {
       $supportedGlobals = $parsedBody.supported_globals
    }

    # Basic input validation
    if ([string]::IsNullOrWhiteSpace($scriptContent)) {
        throw "Script content cannot be empty"
    }

    # If context is a string, try to deserialize it
    if ($contextData -is [string]) {
        $contextData = $contextData | ConvertFrom-Json
    }

    if ($supportedGlobals -is [string]) {
        $supportedGlobals = $supportedGlobals | ConvertFrom-Json
    }

    # Set up the CTX and supported global variables in the global scope
    if ($supportedGlobals) {
        foreach ($globalVar in $supportedGlobals.PSObject.Properties) {
            Set-Variable -Name "Global:$($globalVar.Name)" -Value $globalVar.Value
        }
    }
    $Global:CTX = $contextData

    # Create the script block
    $scriptBlock = [ScriptBlock]::Create($scriptContent)

    # Execute the script and capture output
    $output = & {
        $ErrorActionPreference = 'Stop'
        try {
            & $scriptBlock
        }
        catch {
            throw $_
        }
    }

    # Set success and convert output to JSON
    $Response.Body.Success = $true
    $Response.Body.Output = $output | Convert-ToJsonSafe -ThrowOnInvalid
}
catch {
    $Response.StatusCode = 400
    $Response.Body.Error = @{
        Message = $_.Exception.Message
        ScriptStackTrace = $_.ScriptStackTrace
        Position = @{
            Line = $_.InvocationInfo.ScriptLineNumber
            Column = $_.InvocationInfo.OffsetInLine
        }
        RawInput = $requestBody
    }
}
finally {
    # Clean up supported globals if they were created
    if ($supportedGlobals) {
        foreach ($globalVar in $supportedGlobals.PSObject.Properties) {
            Remove-Variable -Name $globalVar.Name -Scope Global -ErrorAction SilentlyContinue
        }
    }
    if (Get-Variable -Name CTX -ErrorAction SilentlyContinue) {
        # Remove the CTX variable
        Remove-Variable -Name CTX -Scope Global -ErrorAction SilentlyContinue
    }
}

# Return the response
Push-OutputBinding -Name Response -Value $Response
