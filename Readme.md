# iamtunnel

> Native macOS menu bar app for managing AWS SSM port-forwarding tunnels.

Connect to your RDS, Redis, and internal services through AWS SSM — without touching the terminal.

**[Website](https://iamtunnel.com)** · **[Download](https://github.com/AdarshJais/iamtunnel/releases/latest/download/iamtunnel.dmg)** · **[Releases](https://github.com/AdarshJais/iamtunnel/releases)**

---

## Download

**[Download for macOS →](https://github.com/AdarshJais/iamtunnel/releases/latest)**

Requires macOS 13 Ventura or later.

---

## Prerequisites

Before using iamtunnel, make sure you have:

- **AWS CLI v2** — [Install](https://aws.amazon.com/cli/)
- **AWS Session Manager Plugin** — [Install](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- **AWS credentials configured** — run `aws configure` or set up SSO
- **MFA enabled on your IAM user** — required if your account policies condition access on `aws:MultiFactorAuthPresent`
- **IAM permissions** — your role needs `ssm:StartSession` on `AWS-StartPortForwardingSessionToRemoteHost`, plus `sts:GetSessionToken` and `iam:ListMFADevices`

The app checks for all of these on launch and shows a warning if anything is missing.

---

## Share tunnels with your team

Settings → Connections → **Export…** writes your saved tunnels to a JSON file (names,
SSM targets, hosts, ports; never credentials). A teammate imports it with **Import…** or:

```bash
open "iamtunnel://import?file=/absolute/path/team-connections.json"
```

iamtunnel always shows what it will add and waits for **Add**. Tunnels with an existing
name or local port are skipped, never overwritten. Keep team files somewhere private:
they don't grant access, but they do describe your infrastructure.

```json
{
  "format": "iamtunnel-connections/1",
  "name": "Acme staging",
  "connections": [
    { "name": "Orders DB", "profile": "default", "region": "ap-south-1",
      "ssmTarget": "i-0123456789abcdef0", "remoteHost": "orders-db.abc123.ap-south-1.rds.amazonaws.com",
      "remotePort": 3306, "localPort": 3306, "env": "staging" }
  ]
}
```

## Open tunnels from scripts and coding agents

iamtunnel 1.2.0+ handles `iamtunnel://` links, so a script or an agent like Claude Code
can ask for a saved tunnel and just wait for the port:

```bash
open -g "iamtunnel://connect?name=My%20DB"      # or ?port=3307
open -g "iamtunnel://disconnect?name=My%20DB"
```

The MFA prompt appears only when the session has expired. Already-open ports are left
alone, and tunnels marked **production** are never opened by a link.

## MFA

Most orgs now require an MFA-authenticated session for CLI actions, which means a
plain access key isn't enough — every call has to carry a temporary session token
issued after an MFA challenge. iamtunnel does that for you.

### One-time console setup

1. Sign in to the AWS Console with your IAM credentials
2. Click your username (top right) → **Security credentials**
3. Under **Multi-factor authentication (MFA)** → **Assign MFA device**
4. Choose **Authenticator app** → **Next** (Google Authenticator, Microsoft Authenticator, and Authy all work)
5. Scan the QR code, then enter two consecutive codes → **Add MFA**
6. While you're there, generate your **Access keys** and put them in `~/.aws/credentials`

### In the app

With **Require MFA session** on (Settings → Security, on by default), connecting a
tunnel asks for the 6-digit code from your authenticator app. iamtunnel then runs
the same flow you'd run by hand:

```bash
# 1. find your MFA device ARN
aws iam list-mfa-devices --query 'MFADevices[0].SerialNumber' --output text

# 2. exchange a code for temporary credentials
aws sts get-session-token \
  --serial-number arn:aws:iam::<account-id>:mfa/<device-name> \
  --token-code 123456 \
  --duration-seconds 43200

# 3. use them for every subsequent call
export AWS_ACCESS_KEY_ID="ASIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
```

The returned `AccessKeyId` / `SecretAccessKey` / `SessionToken` are injected as
environment variables into each `aws` process the app spawns. `AWS_SESSION_TOKEN`
is the part that proves the session is MFA-authenticated, so `--profile` is
deliberately **not** passed while a session is active — the AWS CLI prefers a named
profile's long-term keys over environment credentials, which would drop the token.

Sessions are:

- **Stored in your macOS Keychain**, never in `~/.aws/credentials` or plain files
- **Scoped per AWS profile** — each profile gets its own session
- **Valid for 1–12 hours** (your choice at the prompt; 12h default)
- **Re-prompted automatically** when they expire or AWS rejects them mid-tunnel

Settings → Security shows the active session, when it expires, and a **Verify**
button that runs `aws sts get-caller-identity` and prints the ARN it comes back with.

> If your policies deny `iam:ListMFADevices` without a session, iamtunnel derives
> the device ARN from your caller identity — and if that doesn't match, the prompt
> lets you paste the ARN once and remembers it.

If your account doesn't enforce MFA, turn **Require MFA session** off and the app
falls back to `--profile` as before.

---

## Installation

1. Download `iamtunnel.dmg` from [Releases](https://github.com/AdarshJais/iamtunnel/releases/latest)
2. Open the DMG and drag **iamtunnel** into your Applications folder
3. First launch — Gatekeeper will block it since the app is unsigned:
   - Right-click the app → **Open** → click **Open** in the dialog
   - You only need to do this once

---

## Usage

### Add a connection

1. Click the iamtunnel icon in your menu bar
2. Click **+ New connection**
3. Fill in the details:

| Field | Description | Example |
|---|---|---|
| Name | A friendly label | `Production Postgres` |
| Env | Environment tag | `prod` / `stage` / `dev` |
| AWS Profile | Profile from `~/.aws/config` | `default` |
| Region | AWS region (auto-fills from RDS endpoint) | `ap-south-1` |
| SSM Target | Instance ID or EC2 Name tag | `i-0abc123def456` |
| Remote Host | Host reachable from the instance | `mydb.cluster.ap-south-1.rds.amazonaws.com` |
| Remote Port | Port on the remote host | `3306` |
| Local Port | Port to open on localhost | `3306` |

> **Tip:** Paste an RDS endpoint into Remote Host and the region auto-fills. AWS profiles load automatically from `~/.aws/config`.

### Connect

- Hover over a tunnel → click **Connect**
- The status dot turns **green** when the tunnel is ready
- Point your DB client at `localhost:<localPort>`

### Stop

- Hover over a connected tunnel → click **Stop**
- All tunnels are automatically disconnected when you quit the app

### Edit / Delete

- Right-click any tunnel → **Edit...** or **Delete**

---

## How it works

Under the hood each tunnel runs:

```bash
aws ssm start-session \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<remoteHost>"],"portNumber":["<remotePort>"],"localPortNumber":["<localPort>"]}' \
  --region <region>
```

With an MFA session active, the process environment carries
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` and
`--profile` is omitted. Without MFA, `--profile <profile>` is passed instead.

If you enter a Name tag instead of an instance ID, the app resolves it automatically via `ec2 describe-instances`.

Connections are saved to:
```
~/Library/Application Support/iamtunnel/connections.json
```

---

## Settings

| Setting | Description |
|---|---|
| Require MFA session | Prompt for an authenticator code and use temporary session credentials (on by default) |
| Session length | How long `sts get-session-token` credentials stay valid — 1h / 4h / 8h / 12h |
| Notify on session change | Alert when an MFA session starts or expires |
| Launch at login | Start iamtunnel automatically on login (requires app in `/Applications`) |
| Notify on connect | Show a notification when a tunnel connects |
| Notify on disconnect | Show a notification when a tunnel drops |
| Show active count | Display active tunnel count in the menu bar icon |

---

## Troubleshooting

**`aws: command not found`**
AWS CLI is not on the app's PATH. Make sure it's installed at `/usr/local/bin/aws` or `/opt/homebrew/bin/aws`.

**Tunnel stays in "Starting..." state**
- Check the Session Manager Plugin is installed
- Verify your IAM role has `ssm:StartSession` permission
- Confirm the instance is running and SSM agent is active
- Double check the region is correct

**Port already in use**
The app automatically detects and kills the existing process on that port before connecting.

**MFA prompt keeps coming back**
- The session length may be shorter than your account's max — try 1h to confirm the flow works, then raise it
- Check the clock on your phone; a drifting authenticator clock produces codes AWS rejects
- Enter two *consecutive* codes only during console setup — the app needs just one

**"Couldn't find your MFA device ARN"**
Your policy likely denies `iam:ListMFADevices` without a session. Paste the ARN from
AWS Console → Security credentials into the prompt; it's remembered after that.

**Instance not found in SSM**
- Verify the region matches the instance's region
- Check IAM permissions
- Confirm the SSM agent is running on the instance

---

## Building from source

```bash
# Clone the repo
git clone https://github.com/AdarshJais/iamtunnel.git
cd iamtunnel

# Open in Xcode
open iamtunnel.xcodeproj

# Build and run
# Press Cmd+R in Xcode
```

**Requirements:**
- Xcode 15+
- macOS 13 SDK
- Swift 5.9+

---

## Contributing

Issues and PRs are welcome! Please open an issue first for major changes.

---

## License

MIT — see [LICENSE](LICENSE)