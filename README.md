# Azure-Status

An automated infrastructure cost-tracking and availability reporting engine. This repository provisions a self-contained **GitHub Actions** pipeline that logs into Azure daily, parses consumption metrics, snaps real-time visual screenshots of active web deployments, and prepares a report directly to a target **Slack** channel using Slack Block Kit.

---

## Features

* **Automated Cost Monitoring:** Queries the Azure Consumption Management API to extract Month-to-Date (MTD) PAYG billing allocations per resource.
* **Visual Health Assurances:** Deploys a headless Chromium browser instance dynamically using `shot-scraper` and `playwright` to capture live website renders.
* **Zero-Overhead Image Tracking:** Automatically commits and replaces diagnostic screenshots inside the repository using dynamic cache-busting strings to update Slack natively.
* **Secure Infrastructure Mapping:** Eliminates hardcoded authorization credentials by leveraging native GitHub Secrets integration and read-only Azure Service Principals.

---

## Repository Architecture

The project consists of two core moving pieces:
1.  **.github/workflows/daily-billing.yml**: The automation driver that provisions the system runtime environment, activates Python/PowerShell packages, handles cloud authentication, and commits fresh snapshots.
UPDATE [22/06/2026]: GitHub Action cron schedule was unreliable and not working. Created a separate GitLab project that houses a single YAML script to be executed in a scheduled pipeline daily to trigger this GitHub Action through HTTP POST.
3.  **Query_Azure.ps1**: The logic execution file responsible for fetching REST APIs, analyzing JSON trees, verifying endpoint `200 OK` status headers, and assembling the compressed Slack Block Kit payload.

---

## Required GitHub Secrets

To run this pipeline successfully, **Repository Secrets** must be configured under `Settings > Secrets and variables > Actions`:

| Secret Name | Type | Description |
| :--- | :--- | :--- |
| `AZURE_CREDENTIALS` | `JSON` | Full authentication payload containing the `clientId`, `clientSecret`, `subscriptionId`, and `tenantId` (Service Principal with `Reader` role). |
| `AZURE_SUBSCRIPTION_ID` | `String` | The explicit target UUID of the Azure Subscription tracking the usage meters. |
| `SLACK_WEBHOOK_URL` | `String` | The unique incoming webhook endpoint provided by your Slack App integration directory. |

---

## Configuration Setup

### 1. Script Variables
The script automatically discovers endpoints linked to the Static Web Apps by looking for assets containing `"myresume"`. Ensure the custom domains are mapped natively within the Azure portal so they append seamlessly to the automated verification array.

### 2. Local Debugging
The script can be excuted locally for development testing. The code contains an execution guard loop that skips the heavy browser installation layers outside of CI environments:
```powershell
./Query_Azure.ps1
