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
    
    pip install shot-scraper playwright --quiet
    
    playwright install chromium --with-deps
    
    for ($i = 0; $i -lt $UrlArray.Count; $i++) {
        $TargetUrl = $UrlArray[$i]
        $CleanFileName = $TargetUrl -replace "https://", "" -replace "/", "-"
        $FileName = "screenshot-$CleanFileName.png"
        $ScreenshotPath = "docs/$FileName"
        
        Write-Host "Capturing: $TargetUrl -> $ScreenshotPath"
        shot-scraper $TargetUrl -o $ScreenshotPath --width 1280 --height 800 --wait 5000
        
        $GitHubRawUrl = "https://raw.githubusercontent.com/Lacketronik/Azure-Status/main/docs/$FileName"
        
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
        text = @{ type = 'mrkdwn'; text = '*Static Web App Availability Manifest*' }
    },
    @{
        type = 'section'
        fields = $UrlFields
    }
)

$Payload = @{ blocks = $SlackBlocks } | ConvertTo-Json -Depth 10 -Compress
#===========================================================================================================================================================================================





#Send to Slack
#===========================================================================================================================================================================================
Write-Host "Shipping native Block Kit payload directly to Slack..."
Invoke-RestMethod -Method Post -Uri $WebHookURL -Body $Payload -ContentType "application/json; charset=utf-8"
Write-Host "Complete!"
#===========================================================================================================================================================================================
