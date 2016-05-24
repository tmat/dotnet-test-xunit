$solutionPath = split-path $MyInvocation.MyCommand.Definition
$toolsPath = join-path $solutionPath ".dotnet"
$getDotNet = join-path $toolsPath "install.ps1"
$nugetExePath = join-path $toolsPath "nuget.exe"

write-host "Download latest install script from CLI repo"

New-Item -type directory -f -path $toolsPath | Out-Null

Invoke-WebRequest https://raw.githubusercontent.com/dotnet/cli/rel/1.0.0/scripts/obtain/dotnet-install.ps1 -OutFile $getDotNet

$env:DOTNET_INSTALL_DIR="$solutionPath\.dotnet\win7-x64"

if (!(Test-Path $env:DOTNET_INSTALL_DIR)) {
    New-Item -type directory -path $env:DOTNET_INSTALL_DIR | Out-Null
}

$globalJson = (get-content (join-path $solutionPath "global.json")) | ConvertFrom-Json

& $getDotNet -arch x64 -version $globalJson.sdk.version

$env:PATH = "$env:DOTNET_INSTALL_DIR;$env:PATH"

$autoGeneratedVersion = $false

# Generate version number if not set
if ($env:BuildSemanticVersion -eq $null) {
    $autoVersion = [math]::floor((New-TimeSpan $(Get-Date) $(Get-Date -month 1 -day 1 -year 2016 -hour 0 -minute 0 -second 0)).TotalMinutes * -1).ToString() + "-" + (Get-Date).ToString("ss")
    $env:BuildSemanticVersion = "99.99.99-dev-" + $autoVersion
    $autoGeneratedVersion = $true
    
    Write-Host "Set version to $autoVersion"
}

Get-ChildItem */*/project.json | %{ echo $_.FullName } | %{
    $content = get-content "$_"
    $content = $content.Replace("99.99.99-dev", "$env:BuildSemanticVersion")
    set-content "$_" $content -encoding UTF8
}

# Restore packages and build product
& dotnet restore "src\dotnet-test-xunit" --infer-runtimes
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE"
}

$outputDir = "$PWD\src\dotnet-test-xunit\bin\Release"
$extractDirectory = "$PWD\src\dotnet-test-xunit\obj\extract"
if (Test-Path $outputDir) {
    Remove-Item -r -force $outputDir
}

if (Test-Path $extractDirectory) {
    Remove-Item -r -force $extractDirectory
}

& dotnet pack "src\dotnet-test-xunit" --configuration Release -o $outputDir

$nupkgFile = Get-ChildItem $outputDir *.nupkg | ?{ !$_.Name.Contains("symbols") } | Select -First 1
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($nupkgFile.FullName, $extractDirectory)

$x64Dir = New-Item -type directory -path "$extractDirectory\runtimes\win7-x64\lib\net451\"
$x86Dir = New-Item -type directory -path "$extractDirectory\runtimes\win7-x86\lib\net451\"
$unixDir = New-Item -type directory -path "$extractDirectory\runtimes\unix-x64\lib\net451\"
Copy-Item $extractDirectory\lib\net451\dotnet-test-xunit.exe $x64Dir\dotnet-test-xunit.exe
Copy-Item $extractDirectory\lib\net451\dotnet-test-xunit.exe $unixDir\dotnet-test-xunit.exe

# Compile for net451 win7-x86
& dotnet build "src\dotnet-test-xunit" --configuration release_x86 -f net451 --no-dependencies
Copy-Item $outputDir\..\release_x86\net451\dotnet-test-xunit.exe $x86Dir\dotnet-test-xunit.exe

Remove-Item $nupkgFile.FullName
if (Test-Path $PWD\artifacts) {
    Remove-Item -r -force $PWD\artifacts
}

New-Item -type directory -path $PWD\artifacts\packages | Out-Null

@('_rels', '[Content_Types].xml') | %{
    $pathToDelete = Join-Path $extractDirectory $_
    if (Test-Path -LiteralPath $pathToDelete) {
        Remove-Item -r -force -literalPath $pathToDelete
    }
}

# Download latest nuget
if (!(Test-Path $nugetExePath)) {
    Invoke-WebRequest -Uri https://dist.nuget.org/win-x86-commandline/v3.4.2-rc/nuget.exe -OutFile $nugetExePath
}

& $nugetExePath pack $extractDirectory\dotnet-test-xunit.nuspec -out $PWD\artifacts\packages

#restore, compile, and run tests
& dotnet restore "test" -f "artifacts\packages"
Get-ChildItem "test" | ?{ $_.PsIsContainer } | %{
    pushd "test\$_"
    & dotnet test
    popd
}

Get-ChildItem */*/project.json | %{ echo $_.FullName } | %{
    $content = get-content "$_"
    $content = $content.Replace("$env:BuildSemanticVersion", "99.99.99-dev")
    set-content "$_" $content -encoding UTF8
}

if ($autoGeneratedVersion) {
    $env:BuildSemanticVersion = $null
}
