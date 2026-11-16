# Voice: the words the app and `uptf` use

Everything a person reads in the Mac app (menus, buttons, windows, messages) and in `uptf`'s help and
output uses the same plain words as uploadthefile.com. The people who use it do not need to know what
*host*, *deploy* or *URL* mean: say "publish", "your link", "your own web address", "stays online".
When the website's wording changes, change this page and the strings together.

## Plain words

| Say this | Not this |
| --- | --- |
| publish, put online, get a link, stays online | host, hosting, deploy |
| website | static website |
| link, address | URL |
| check | validate |
| opens | render |
| the web address you already own | custom domain |
| ask for their email first | email gate |
| see how many people opened it | click analytics |
| badge | branding |
| stays online | retention, expiry |
| (removed) | repository, build step, server |

## The words in the app

| Where | Words |
| --- | --- |
| Main action | **Choose File…** (header button, menu bar right-click; the file picker's button says **Publish**), **Publish with Upload the File** (Finder) |
| Drop hint | **Release to publish** |
| Confirmation | "Publish “X”?" with the button **Publish**; with a warning "Publish “X”? It may be sensitive" |
| Copy a link | **Copy Link**, **Copy Upload the File Link** (Finder) |
| Changed file | **Replace File** / **Replace Folder** (the link stays the same) |
| Same thing again | **Publish as a New Link** |
| Remove | **Delete…** (the file and its link; people who have the link can no longer open it). CLI: `uptf delete` |
| Link settings | **Set Up Link…** (window: "Set up your link"), **Link name**, **Rename** |
| Password | **Password protection**: "Only people with the password can open it." |
| Email | **Ask for their email first** |
| Expiry | **Stays online**: "Stays online until I delete it", or until a date |
| Display | **How it opens**: "It opens right in the browser", "With a download button", "Download button only" |
| Progress | "Uploading…" is the only place *upload* is used; "Replacing…" for a replace |
| Done | "“X” is published. Link copied." |
| Nothing went out | "Nothing was published." |
| Empty list | "Nothing published yet" and "Files and folders you publish appear here." |
| Tip | "Drop files on the menu bar icon, or right-click a file in Finder." |
| Updates | **Check for Updates…**; with a new version waiting, **Update to 0.1.3…**; notification "Update available" / "Upload the File 0.1.3 is available." (Sparkle's own window keeps its wording) |
| Finder, nothing to copy | "Not published yet" ("“X” isn't published from this Mac yet. Choose “Publish with Upload the File” first.") |
| Link in a list row | The link itself, e.g. `launch-notes.upload.tf`, opens in the browser; the rest of the row and the copy icon copy it ("Copy Link", then "Link copied") |
| Dashboard | **Manage Files on uploadthefile.com** |
| Folder with index.html | "This folder has an index.html, so it opens as a website." |
| Too many requests | "Too many changes in a short time. Try again in N minutes." |
| Not found | "This link isn't in your account anymore." |

Avoid in anything a person reads: host, hosting, deploy, unpublish, URL, slug, page id, entry, MIME,
zip (as a verb: say "folder" and "files"), cache, token, OAuth, scope, HTTP status codes, server.
(*Publish* and *published* are fine; the removal is **Delete**, never "unpublish".)

Plan messages that come from the server ("Password protection is available on Pro and above") are
shown word for word, so the app and the website always say the same thing.

Sentence case for body text; Title Case for buttons and menu items (macOS Human Interface Guidelines).

## What stays technical

Code identifiers (`publish`, `PublishSession`, `UptfClient.unpublish`, `hostAsSite`), the API,
file and flag names, and the developer docs keep their technical terms. The CLI keeps `publish` and
`update` as command names, and its flags; `uptf publish` is described as "Publish a file or folder
and get its link."
