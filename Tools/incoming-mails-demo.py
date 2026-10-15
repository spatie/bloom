#!/usr/bin/env python3
"""Send three local test messages to Bloom's incoming mail inbox."""

import argparse
import smtplib
from email.message import EmailMessage


def message(subject: str, recipient: str) -> EmailMessage:
    mail = EmailMessage()
    mail["From"] = "Bloom Demo <demo@bloom.test>"
    mail["To"] = recipient
    mail["Subject"] = subject
    return mail


def examples() -> list[EmailMessage]:
    plain = message("Bloom demo: plain text", "plain@example.test")
    plain.set_content("This is a plain text message sent to the built-in inbox for testing Bloom.\n")

    html = message("Bloom demo: HTML and link", "html@example.test")
    html.set_content("Open https://example.com to test a link from a message.\n")
    html.add_alternative(
        '<html><body style="font-family: system-ui; padding: 24px">'
        '<h1>Bloom incoming mail demo</h1><p>This message has an HTML body.</p>'
        '<p><a href="https://example.com">Open a test link</a></p>'
        '</body></html>',
        subtype="html",
    )

    attachment = message("Bloom demo: attachment", "files@example.test")
    attachment["Cc"] = "reviewer@example.test"
    attachment.set_content("Use the attachment chip to preview or save the included CSV.\n")
    attachment.add_attachment(
        b"item,quantity\nNotebook,2\nPen,3\n",
        maintype="text",
        subtype="csv",
        filename="demo-items.csv",
    )

    return [plain, html, attachment]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1025)
    args = parser.parse_args()

    with smtplib.SMTP(args.host, args.port, timeout=10) as smtp:
        for mail in examples():
            smtp.send_message(mail)
            print(mail["Subject"])


if __name__ == "__main__":
    main()
