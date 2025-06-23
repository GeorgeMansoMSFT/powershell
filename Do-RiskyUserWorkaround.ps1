# Requires Microsoft.Graph.Identity.SignIns module
# Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser

param (
    [Parameter(Mandatory = $false)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [datetime]$StartDate,

    [Parameter(Mandatory = $false)]
    [datetime]$EndDate
)

Connect-MgGraph -Scopes "User.ReadWrite.All", "IdentityRiskyUser.ReadWrite.All" -NoWelcome

if (-not $UserPrincipalName -and (-not $StartDate -or -not $EndDate)) {
    Write-Host "Please specify either a UserPrincipalName or both StartDate and EndDate."
    return
}

if ($UserPrincipalName) {
    # Process single user
    $riskyUser = Get-MgRiskyUser -Filter "userPrincipalName eq '$UserPrincipalName'"
    if (-not $riskyUser) {
        Write-Host "Risky user not found for UPN: $UserPrincipalName"
        return
    }
    $riskyUsers = @($riskyUser)
} else {
    # Get all risky users
    $riskyUsers = Get-MgRiskyUser -All | Where-Object {
        $_.RiskLastUpdatedDateTime -ge $StartDate -and $_.RiskLastUpdatedDateTime -le $EndDate
    }
}

foreach ($user in $riskyUsers) {
    $userId = $user.Id
    $riskState = $user.RiskState
    $isProcessing = $user.IsProcessing
    $lastUpdated = [datetime]$user.RiskLastUpdatedDateTime

    if ($isProcessing) {
        Write-Host "User $($user.UserPrincipalName) is currently processing. Skipping."
        continue
    }

    # PART 1: Mark as compromised if not none, confirmedCompromised, or dismissed
    if ($riskState -ne "none" -and $riskState -ne "confirmedCompromised" -and $riskState -ne "dismissed") {
        Write-Host "User $($user.UserPrincipalName): Risk state is '$riskState'. Marking as compromised..."
        Confirm-MgRiskyUserCompromised -UserIds $userId
    }
    # PART 2: If confirmedCompromised, dismiss risk
    elseif ($riskState -eq "confirmedCompromised") {
        Write-Host "User $($user.UserPrincipalName): Risk state is 'confirmedCompromised'. Dismissing risk..."
        Invoke-MgDismissRiskyUser -UserIds $userId
    }
    else {
        Write-Host "User $($user.UserPrincipalName): Risk state is '$riskState'. No eligible action taken."
    }
}
