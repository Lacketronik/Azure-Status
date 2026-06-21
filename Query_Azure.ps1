$WebHookURL = $env:SLACK_WEBHOOK_URL
$SubscriptionID = $env:AZURE_SUBSCRIPTION_ID

if ([string]::IsNullOrEmpty($WebHookURL) -or [string]::IsNullOrEmpty($SubscriptionID)) {
    Write-Error "Error: Missing required environment variables! Check GitHub Secrets."
    exit 1
}

# Get Billing
#===========================================================================================================================================================================================
az rest --method get --uri "https://management.azure.com/subscriptions/$SubscriptionID/providers/Microsoft.Consumption/usageDetails?api-version=2021-10-01" --output json > raw_billing.json

$BillingData = Get-Content -Raw -Path ".\raw_billing.json" | ConvertFrom-Json

$GroupedData = $BillingData.value | Group-Object -Property { $_.properties.instanceName }

$ProcessedResources = foreach ($Bucket in $GroupedData) {
    $Sum = 0
    foreach ($Record in $Bucket.Group) {
        $Sum += $Record.properties.paygCostInUSD
    }
    
    [PSCustomObject]@{
        Name = $Bucket.Name.Split('/')[-1]
        Cost = [Math]::Round($Sum, 5)
    }
}
#===========================================================================================================================================================================================


# Get Static Web App
#===========================================================================================================================================================================================
$ActiveAssets = az resource list --output json | ConvertFrom-Json
$WebAssets = $ActiveAssets | Where-Object { $_.name -like "*myresume*" }
$WebDetails = az rest --method get --uri "https://management.azure.com/subscriptions/$SubscriptionID/resourceGroups/$($WebAssets.resourceGroup)/providers/Microsoft.Web/staticSites/$($WebAssets.name)?api-version=2025-05-01" | ConvertFrom-Json
$WebURI = $WebDetails.properties.defaultHostname
$CustomDomains = $WebDetails.properties.customDomains
$UrlArray = @(
    "https://$WebURI"
)
foreach ($Domain in $CustomDomains) {
    $UrlArray += "https://$Domain"
}

$UrlTable = foreach ($Url in $UrlArray) {
    [PSCustomObject]@{
        "Target URL"  = $Url
        "Status Code" = (Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing).StatusCode
    }
}
#===========================================================================================================================================================================================





# Screenshot WebApp
#===========================================================================================================================================================================================
if (!(Test-Path "docs")) { New-Item -ItemType Directory -Path "docs" }

$SlackImageBlocks = @()

if ($env:GITHUB_ACTIONS -eq "true") {
    Write-Host "Running in GitHub Actions. Bootstrapping Headless Browser..."
    
    pip install shot-scraper playwright pillow --quiet
    
    playwright install chromium --with-deps

    $UtcTime = [DateTime]::UtcNow
    $SgtZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Singapore Standard Time")
    $SgtTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($UtcTime, "Singapore Standard Time")
    $TimestampText = "Captured: $($SgtTime.ToString('yyyy-MM-dd HH:mm')) SGT"
    
    for ($i = 0; $i -lt $UrlArray.Count; $i++) {
        $CacheBuster = Get-Date -Format "yyyyMMddHHmmss"
        $TargetUrl = $UrlArray[$i]
        $CleanFileName = $TargetUrl -replace "https://", "" -replace "/", "-"
        $FileName = "screenshot-$CleanFileName.png"
        $ScreenshotPath = "docs/$FileName"
        
        Write-Host "Capturing: $TargetUrl -> $ScreenshotPath"
        shot-scraper $TargetUrl -o $ScreenshotPath --width 1280 --height 800 --wait 5000

        if (Test-Path $ScreenshotPath) {
            Write-Host "Watermarking timestamp onto $FileName..."
            python -c @"
from PIL import Image, ImageDraw, ImageFont
import os

img_path = '$ScreenshotPath'
if os.path.exists(img_path):
    img = Image.open(img_path).convert('RGBA')
    txt = Image.new('RGBA', img.size, (255,255,255,0))
    
    d = ImageDraw.Draw(txt)
    
    d.rectangle([img.size[0] - 340, img.size[1] - 60, img.size[0] - 10, img.size[1] - 10], fill=(0,0,0,160))
    
    d.text((img.size[0] - 330, img.size[1] - 52), '$TargetUrl', fill=(255,255,255,255))
    
    d.text((img.size[0] - 330, img.size[1] - 30), '$TimestampText', fill=(255,255,255,255))
    
    final_img = Image.alpha_composite(img, txt).convert('RGB')
    final_img.save(img_path, 'PNG')
"@
        }
        
        $GitHubRawUrl = "https://raw.githubusercontent.com/Lacketronik/Azure-Status/main/docs/$FileName`?v=$CacheBuster"
        
        $SlackImageBlocks += @{
            type = 'image'
            title = @{ type = 'plain_text'; text = "Visual Check: $CleanFileName" }
            image_url = $GitHubRawUrl
            alt_text = $CleanFileName
        }
        
        if ($i -lt ($UrlArray.Count - 1)) { $SlackImageBlocks += @{ type = 'divider' } }
    }
} else {
    Write-Host "Local execution detected. Skipping headless screenshots to avoid environment errors."
}
#===========================================================================================================================================================================================





# Create Tables for Slack Message
#===========================================================================================================================================================================================
$BillingFields = @()
foreach ($Item in $ProcessedResources) {
    $NameString = '• `' + $Item.Name + '`'
    $CostString = '*' + $Item.Cost + ' USD*'

    $BillingFields += @{ 
        type = 'mrkdwn'
        text = $NameString 
    }
    $BillingFields += @{ 
        type = 'mrkdwn'
        text = $CostString 
    }
}

if ($BillingFields.Count -eq 0) {
    $BillingFields += @{ type = 'mrkdwn'; text = '_No active billing meters_' }
    $BillingFields += @{ type = 'mrkdwn'; text = '_$0.00_' }
}

$UrlFields = @()
foreach ($Row in $UrlTable) {
    $UrlString = '🌐 `' + $Row.'Target URL' + '`'
    
    $StatusMarker = '🔴 ' + $Row.'Status Code'
    if ($Row.'Status Code' -eq 200) { 
        $StatusMarker = '🟢 200 OK' 
    }
    $StatusString = '*' + $StatusMarker + '*'
    
    $UrlFields += @{ 
        type = 'mrkdwn'
        text = $UrlString 
    }
    $UrlFields += @{ 
        type = 'mrkdwn'
        text = $StatusString 
    }
}
#===========================================================================================================================================================================================





# Construct Slack Body Message
#===========================================================================================================================================================================================
$SlackBlocks = @(
    @{
        type = 'header'
        text = @{ type = 'plain_text'; text = 'Infrastructure Cost & Health Report'; emoji = $true }
    },
    @{ type = 'divider' },
    @{
        type = 'section'
        text = @{ type = 'mrkdwn'; text = '*Month-to-Date PAYG Consumption*' }
    },
    @{
        type = 'section'
        fields = $BillingFields
    },
    @{ type = 'divider' },
    @{
        type = 'section'
        text = @{ type = 'mrkdwn'; text = '*Static Web App Availability*' }
    },
    @{
        type = 'section'
        fields = $UrlFields
    }
)

if ($SlackImageBlocks.Count -gt 0) {
    $SlackBlocks += @{ type = 'divider' }
    $SlackBlocks += $SlackImageBlocks
}

$Payload = @{ blocks = $SlackBlocks } | ConvertTo-Json -Depth 10 -Compress
#===========================================================================================================================================================================================





# Write Payload out so that Slack can pick it up after Git Commit the images
#===========================================================================================================================================================================================
$Payload | Out-File -FilePath "slack_payload.json" -Encoding utf8
Write-Host "Payload cached locally. Ready for Git deployment!"
#===========================================================================================================================================================================================
