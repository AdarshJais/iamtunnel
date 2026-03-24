# iamtunnel

> Native macOS menu bar app for managing AWS SSM port-forwarding tunnels.

Connect to your RDS, Redis, and internal services through AWS SSM — without touching the terminal.

**[Website](https://iamtunnel.com)** · **[Download](https://github.com/AdarshJais/iamtunnel/releases/download/v1.0.1/iamtunnel.dmg)** · **[Releases](https://github.com/AdarshJais/iamtunnel/releases)**

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
- **IAM permissions** — your role needs `ssm:StartSession` on `AWS-StartPortForwardingSessionToRemoteHost`

The app checks for all of these on launch and shows a warning if anything is missing.

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
  --profile <profile> \
  --region <region>
```

If you enter a Name tag instead of an instance ID, the app resolves it automatically via `ec2 describe-instances`.

Connections are saved to:
```
~/Library/Application Support/iamtunnel/connections.json
```

---

## Settings

| Setting | Description |
|---|---|
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