# Enable installing from a powershell command
#
# For example
# To install the latest version: 
# $ProgressPreference = "silentlyContinue"; 
# iex ((New-Object System.Net.WebClient).DownloadString('https://tools.veracode.com/veracode-cli/install.ps1'))
#
# To install the specific version: 
# $scriptPath = ((new-object net.webclient).DownloadString('https://tools.veracode.com/veracode-cli/install.ps1')); 
# Invoke-Command -ScriptBlock ([scriptblock]::Create($scriptPath)) -ArgumentList "1.9.0"
#

param (
    [string]$version,
    [string]$proxyUrl
)


function Get-Downloader {
    $webClient = New-Object System.Net.WebClient
    if ($proxyUrl) {
        if ($proxyUrl -notmatch '^http://') {
            throw "Invalid proxy URL. Only 'http://' is supported. Received: $proxyUrl"
        }
        try {
            $uri = [System.Uri]::new($proxyUrl)
        } catch {
            throw "Invalid proxy URL format: $proxyUrl. Ensure it is a valid URL."
        }
        $proxy = New-Object System.Net.WebProxy($proxyUrl, $true)
        $webClient.Proxy = $proxy
    }
    return $webClient
}

function Remove-Old-Version {
    param([string]$destinationDir)
    Write-Debug "Removing from destination directory $destinationDir"
    # Check if the destination directory exists, if not, create it
    if (Test-Path -Path  $destinationDir\veracode -PathType Container) {
        # Delete existing application
        Remove-Item -Path $destinationDir\veracode -Recurse -Force
    }
    # Get the current PATH environment variable
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")

    # Split the PATH variable into individual entries
    $pathEntries = $currentPath -split ";"

    # Remove the unwanted entry
    $newPathEntries = $pathEntries | Where-Object { $_ -ne "$destinationDir\veracode" }

    # Join the remaining entries back into a semicolon-separated string
    $newPath = $newPathEntries -join ";"

    # Set the modified PATH as the new environment variable
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")

    # Optional: Display the modified PATH for verification
    Write-Debug "Modified PATH: $newPath"
}

function Get-Version {
    param([string] $url)
    Write-Debug "Argument received: $version"
    # URL of the executable to download
    if (-not $version) {
        $version = Download-String("$url/LATEST_VERSION")
        Write-Host "Downloading the version: $version"
    }
    $version = $version.trim()
    return $version
}

function Download-String {
    param (
        [string]$url
    )
    Write-Debug "Downloading string from $url"
    $downloader = Get-Downloader

    return $downloader.DownloadString($url)
}

function Check-Arch {
  param ([string]$version, [string]$destinationDir)   
    if([System.Environment]::Is32BitOperatingSystem) {
        Write-Debug "Check-Arch: architecture 36 bit is supported"
        $fileName = "veracode-cli_${version}_windows_386.zip"
        Write-Debug "Destination path $fileName."
        return $fileName
    } elseif([System.Environment]::Is64BitOperatingSystem) {
        Write-Debug "Check-Arch: architecture 64 bit is supported"
        $fileName = "veracode-cli_${version}_windows_x86.zip"
        Write-Debug "Destination path $fileName."
        return $fileName
    } else {
        Write-Debug "Check-Arch: architecture is not x86_32 or x86_64"
        throw "Error: Veracode Interactive only supports x86_32 and x86_64, but your uname -m reported $arch" 
    }

}

function Get-Url {
    param([string]$url, [string]$filename)
    return "$url/$fileName"
}

function Get-Destination {
    param([string]$destinationDir, [string]$fileName) 
    return Join-Path -Path $destinationDir -ChildPath $fileName
}

function Download-Compress-File {
    param([string] $url, [string] $destination)
    # Create a WebClient instance
    $webClient = Get-Downloader

    try {
        # Check if the file exists at the URL
        $response = $null
        if($proxyUrl) {
            $response = Invoke-WebRequest -Uri $url -Proxy $proxyUrl -UseBasicParsing -Method Head -ErrorAction Stop
        } else {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -Method Head -ErrorAction Stop
        }

        if ($response.StatusCode -eq 200) {
            # File exists, proceed with download asynchronously
            $downloadTask = $webClient.DownloadFileTaskAsync($url, $destination)

            # Display a simple progress bar while downloading
            Check-Download-Progress
            Write-Debug "Download complete. File saved to: $destination"
        } else {
            Write-Host "File not found at the specified URL: $url"
        }
    } catch {
        Write-Host "Download failed. URL: $url. Error: $_.Exception.Message"
    } finally {
        # Dispose WebClient object after download completes or fails
        $webClient.Dispose()
    }
}

# Code taken from chocolatey.org/install.ps1
function Extract-Compress-File {
    param ([string] $destination, [string] $destinationDir)
    # Extract the contents of the downloaded ZIP file to a folder
    Write-Debug "Destination path $destination."
    $extractedFolder = Join-Path -Path $destinationDir -ChildPath "veracode-temp"
    Write-Debug "Extraction path to $extractedFolder."
    Expand-Archive -Path $destination -DestinationPath $extractedFolder -Force
    Write-Debug "Extraction completed to $extractedFolder."
}

function Move-To-Veracode-Dir {
    param ([string] $fileName, [string] $destinationDir)
    $folderName =$fileName.Replace(".zip", "")
    $tempDir = "$destinationDir/veracode-temp/$folderName"
    $veracodeDir = "$destinationDir/veracode"
    Write-Debug "Temp dir $tempDir moving to $veracodeDir ."
    Move-Item -Path $tempDir -Destination "$veracodeDir" -Force
    Remove-Item -Path "$destinationDir/veracode-temp" -Force -Recurse
}

function Remove-Compress-File {
    Get-ChildItem -Path $destinationDir\veracode-cli_* -Recurse | Remove-Item -Force -Recurse
}

function Check-Download-Progress {
    while (-not $downloadTask.IsCompleted) {
        $bytesReceived = $webClient.DownloadProgress.BytesReceived
        $totalBytes = $webClient.DownloadProgress.TotalBytesToReceive

        if ($totalBytes -gt 0) {
            $progress = [math]::Round(($bytesReceived / $totalBytes) * 100)
        } else {
            $progress = 0
        }

        Write-Progress -Activity "Downloading File" -Status "Progress: $progress%" -PercentComplete $progress
        Start-Sleep -Seconds 1
    }
}

function Install-Veracode {
    # Add the installation directory to the PATH environment variable
    $installationPath = "$destinationDir\veracode"
    $env:Path += ";$installationPath"

    $pathVariable = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $newPath = "$pathVariable;$installationPath"
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    
    Write-Host "Installation completed."
}

function Main {
    $url = "https://tools.veracode.com/veracode-cli"
    $destinationDir = "$env:APPDATA"
    Remove-Old-Version $destinationDir
    $version = Get-Version $url
    $fileName = Check-Arch $version $destinationDir
    $downloadUrl = Get-Url $url $fileName
    $destination = Get-Destination $destinationDir $fileName
    Download-Compress-File $downloadUrl $destination
    Extract-Compress-File $destination $destinationDir
    Move-To-Veracode-Dir $fileName $destinationDir
    Remove-Compress-File
    Install-Veracode
}


try{
    Write-Debug "Executing installer.ps1!!"
    Main
} catch {
    # Output an error message if download or installation fails
    Write-Host "Installation failed. Please contact support at veracode@support.com for assistance: $_.Exception.Message"

}
