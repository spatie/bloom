#!/usr/bin/env python3
"""Adds one release to Bloom's Sparkle appcast, and prints the result.

    Tools/release/appcast.py --existing appcast.xml --output appcast.xml \
        --version 1.4.0 --build 431 \
        --url https://example/Bloom-1.4.0.zip --length 8123456 \
        --dmg-url https://example/Bloom-1.4.0.dmg --dmg-length 12345678 \
        --signature <edSignature> --min-system 26.0 \
        --channel beta --notes-file notes.html

The enclosure is the zip and only ever the zip. The disk image, when there is
one, is named in a bloom:diskImage element beside it, which the website reads
and Sparkle ignores.

The feed is generated from the release rather than edited by hand. Hand editing
an appcast is how you ship an enclosure whose length does not match its file,
which Sparkle rejects with an error the user cannot act on.

Only the new item needs its zip present. The signature and the byte count come
in as arguments, computed by sign_update against the file that was actually
uploaded, so nothing here has to download every past release to rebuild a feed.

The existing feed is read, the item for this version is replaced if it is
already there, and the rest are kept in place. Being able to run the same
release twice and get the same feed matters: a re-run after a failed upload is
the normal case, not the exception.

Descriptions are written as escaped text rather than CDATA. Sparkle unescapes
either form, and one form for every item means an old item does not change
shape the first time the feed is regenerated.
"""

from __future__ import annotations

import argparse
import email.utils
import sys
import time
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

# The disk image is not Sparkle's business, so it does not go in Sparkle's
# namespace and it does not go in the enclosure. The enclosure is the zip, and
# it stays the zip: it is what every installed copy of Bloom already knows how
# to unpack, and changing it would change how every one of them updates itself.
# This element sits beside it and says where the same release's .dmg is, for
# runbloom.app, which reads this feed to decide what /download hands a person.
# Sparkle keeps the item's unrecognised children in a dictionary and reads the
# ones it knows, so an element it has never heard of costs it nothing.
BLOOM = "https://runbloom.app/xml-namespaces/bloom"
ET.register_namespace("bloom", BLOOM)


def sparkle_tag(name: str) -> str:
    return f"{{{SPARKLE}}}{name}"


def bloom_tag(name: str) -> str:
    return f"{{{BLOOM}}}{name}"


def item_build(item: ET.Element) -> int:
    """The value Sparkle sorts and compares on, as an integer.

    A feed whose items are out of order still works, because Sparkle picks the
    highest rather than the first. Sorting anyway makes the file readable and
    makes the oldest item the one that falls off the end.
    """
    node = item.find(sparkle_tag("version"))
    text = node.text.strip() if node is not None and node.text else ""
    if not text:
        enclosure = item.find("enclosure")
        if enclosure is not None:
            text = enclosure.get(sparkle_tag("version"), "")
    try:
        return int(text)
    except ValueError:
        return -1


def item_identity(item: ET.Element) -> tuple[str, str]:
    build = item.find(sparkle_tag("version"))
    short = item.find(sparkle_tag("shortVersionString"))
    return (
        (build.text or "").strip() if build is not None else "",
        (short.text or "").strip() if short is not None else "",
    )


def load_channel(existing: str | None) -> tuple[ET.Element, ET.Element]:
    if existing:
        try:
            with open(existing, "r", encoding="utf-8") as handle:
                text = handle.read().strip()
        except FileNotFoundError:
            text = ""
        if text:
            root = ET.fromstring(text)
            channel = root.find("channel")
            if channel is None:
                raise SystemExit(f"appcast.py: {existing} has no <channel>")
            return root, channel

    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    return root, channel


def set_text(parent: ET.Element, tag: str, text: str) -> None:
    node = parent.find(tag)
    if node is None:
        node = ET.SubElement(parent, tag)
    node.text = text


def build_item(args: argparse.Namespace) -> ET.Element:
    item = ET.Element("item")

    ET.SubElement(item, "title").text = args.version
    if args.link:
        ET.SubElement(item, "link").text = args.link
    ET.SubElement(item, "pubDate").text = args.pub_date
    ET.SubElement(item, sparkle_tag("version")).text = str(args.build)
    ET.SubElement(item, sparkle_tag("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle_tag("minimumSystemVersion")).text = args.min_system

    # A channel element is what keeps a prerelease invisible to everyone who has
    # not asked for prereleases. Sparkle treats an item with no channel as the
    # default one, so a stable release must not carry the element at all.
    if args.channel:
        ET.SubElement(item, sparkle_tag("channel")).text = args.channel

    if args.notes_file:
        with open(args.notes_file, "r", encoding="utf-8") as handle:
            notes = handle.read().strip()
        if notes:
            ET.SubElement(item, "description").text = notes

    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.url,
            "length": str(args.length),
            "type": "application/octet-stream",
            sparkle_tag("edSignature"): args.signature,
        },
    )

    # Optional, and absent on every item written before disk images existed.
    # Anything reading this has to cope with it not being there, because the
    # releases up to 0.6.0 shipped a zip and nothing else.
    if args.dmg_url:
        ET.SubElement(
            item,
            bloom_tag("diskImage"),
            {
                "url": args.dmg_url,
                "length": str(args.dmg_length),
                "type": "application/x-apple-diskimage",
            },
        )

    return item


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--existing", help="feed to update, missing or empty is fine")
    parser.add_argument("--output", required=True)
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build", required=True, help="CFBundleVersion")
    parser.add_argument("--url", required=True, help="public URL of the zip")
    parser.add_argument("--length", required=True, help="size of the zip in bytes")
    parser.add_argument("--signature", required=True, help="sparkle:edSignature")
    parser.add_argument("--dmg-url", default="", help="public URL of the disk image, if there is one")
    parser.add_argument("--dmg-length", default="0", help="size of the disk image in bytes")
    # Required rather than defaulted. The floor lives in Resources/Info.plist and the
    # workflow reads it from there; a default here is a second copy of it, and the copy was
    # still saying 15.0 for as long as it took anybody to look. An appcast that understates
    # the floor offers a Mac an update it cannot launch.
    parser.add_argument("--min-system", required=True,
                        help="LSMinimumSystemVersion of the build being published")
    parser.add_argument("--channel", default="", help="beta, or empty for the default channel")
    parser.add_argument("--notes-file", help="HTML release notes")
    parser.add_argument("--link", default="", help="link element on the item")
    parser.add_argument("--pub-date", default="")
    parser.add_argument("--feed-title", default="Bloom")
    parser.add_argument("--feed-link", default="", help="public URL of the feed itself")
    parser.add_argument("--feed-description", default="Updates for Bloom")
    parser.add_argument("--max-items", type=int, default=20)
    args = parser.parse_args()

    if not args.pub_date:
        # +0000 rather than the -0000 Python prefers or the GMT it offers.
        # Sparkle parses this with an RFC 822 numeric offset, which is what its
        # own sample feed uses, and the other two spellings are a needless bet.
        args.pub_date = email.utils.formatdate(time.time(), localtime=False, usegmt=False)
        if args.pub_date.endswith("-0000"):
            args.pub_date = args.pub_date[:-5] + "+0000"

    try:
        int(args.build)
    except ValueError:
        raise SystemExit(f"appcast.py: --build must be an integer, got '{args.build}'")

    if int(args.length) <= 0:
        raise SystemExit("appcast.py: --length must be a positive number of bytes")

    # A disk image element with a zero length would be a URL nobody can check
    # the size of, which is the shape of a half wired release step rather than
    # of a release without an image. No URL is fine; a URL with no size is not.
    if args.dmg_url and int(args.dmg_length) <= 0:
        raise SystemExit("appcast.py: --dmg-url needs a positive --dmg-length")

    root, channel = load_channel(args.existing)

    set_text(channel, "title", args.feed_title)
    set_text(channel, "description", args.feed_description)
    set_text(channel, "language", "en")
    if args.feed_link:
        set_text(channel, "link", args.feed_link)

    new_item = build_item(args)

    kept = []
    for item in channel.findall("item"):
        channel.remove(item)
        build, short = item_identity(item)
        # Same build number or same marketing version means the same release.
        # Replacing it rather than appending is what makes a re-run idempotent.
        if build == str(args.build) or (short and short == args.version):
            continue
        kept.append(item)

    items = [new_item] + kept
    items.sort(key=item_build, reverse=True)

    for item in items[: args.max_items]:
        channel.append(item)

    ET.indent(root, space="    ")
    body = ET.tostring(root, encoding="unicode")

    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write('<?xml version="1.0" encoding="utf-8"?>\n')
        handle.write(body)
        handle.write("\n")

    print(f"appcast.py: wrote {args.output} with {min(len(items), args.max_items)} items", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
