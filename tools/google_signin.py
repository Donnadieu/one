"""One's "Sign in with Google": opens the browser, catches Google's answer on a local port,
saves the login where the Google skill looks for it, prints the account's email.
Usage: google_signin.py <client_secret.json> <hermes_home>
"""
import json, os, sys
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.send",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/contacts.readonly",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/documents",
]

secret, home = sys.argv[1], sys.argv[2]
flow = InstalledAppFlow.from_client_secrets_file(secret, SCOPES)
creds = flow.run_local_server(port=0, open_browser=True, timeout_seconds=600,
                              authorization_prompt_message="",
                              success_message="You're signed in. You can close this tab and go back to One.")
email = build("gmail", "v1", credentials=creds, cache_discovery=False).users().getProfile(userId="me").execute()["emailAddress"].lower()
os.makedirs(os.path.join(home, "google_tokens"), exist_ok=True)
for path in (os.path.join(home, "google_tokens", f"{email}.json"),) + ((os.path.join(home, "google_token.json"),) if not os.path.exists(os.path.join(home, "google_token.json")) else ()):
    with open(path, "w") as f:
        f.write(creds.to_json())
    os.chmod(path, 0o600)
print(json.dumps({"email": email}))
