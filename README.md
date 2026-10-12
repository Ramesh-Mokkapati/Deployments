# Component Suite Installer

Packages the Release builds of several C++ repositories into a single Windows Installer package, **`ComponentSuite.msi`**.

There's no source code to compile here. The pipeline downloads the latest **GitHub Release** of each component repo, stages the files and builds the MSI with [WiX Toolset 5](https://wixtoolset.org/). The MSI is published as an artifact of every pipeline run.

## Components

Every component repo publishes a release zip named `<Repo>-<tag>-x64.zip` when a `v*.*.*` tag is pushed.

| Feature | Repository | Taken from the release zip | Installed to |
|---|---|---|---|
| Application Framework | [Application-Framework](https://github.com/Ramesh-Mokkapati/Application-Framework) | `bin/*`, `README.md` | `Application-Framework\` |
| Azure IoT samples | [Azure-IoT-SDK-CPP](https://github.com/Ramesh-Mokkapati/Azure-IoT-SDK-CPP) | sample exes + Azure SDK DLLs | `Azure-IoT-Samples\` |
| DiskForge | [DiskForge](https://github.com/Ramesh-Mokkapati/DiskForge) | `DiskForge.exe` | `DiskForge\` |
| Localisation | [Localisation](https://github.com/Ramesh-Mokkapati/Localisation) | 3 apps + English/French/German DLLs | `Localisation\` |
| Messaging | [Messaging](https://github.com/Ramesh-Mokkapati/Messaging) | everything (apps, MQTT/RabbitMQ/OpenDDS DLLs, `rtps.ini`) | `Messaging\` |
| MFC SQLite demo | [MfcSqLite](https://github.com/Ramesh-Mokkapati/MfcSqLite) | `MfcSqliteApp.exe` | `MfcSqLite\` |
| Porting tools | [Porting](https://github.com/Ramesh-Mokkapati/Porting) | `x86\*` (32-bit COM bridge + Genie), `x64\*` (ClientModified, PortAssist) | `Porting\` |
| Update Managers | [UpdateManagers](https://github.com/Ramesh-Mokkapati/UpdateManagers) | Push/Pull exes | `UpdateManagers\` |

Everything installs under `C:\Program Files\MyComponentSuite\`, with a `MyComponentSuite` shortcut folder on the desktop. During setup the user can choose which features to install and where. The folder name comes from the `InstallFolderName` build property (see [Building locally](#building-locally)).

Each repo's **latest release** is used. That is GitHub's "latest", which skips drafts and pre-releases (tags like `v1.2.0-rc1`). To pin a component to a specific version, add `"tag": "v1.2.0"` to its entry in `artifacts.json`. Release assets never expire. `.pdb`, `.lib`, `.exp` and `.ilk` files are never packaged.

## Repository layout

```
.github/workflows/build-msi.yml   pipeline: fetch releases -> build MSI -> upload
artifacts.json                    which release zip/files to take from each repo
build.ps1                         local entry point (fetch + build)
scripts/Fetch-Artifacts.ps1       downloads + stages release zips into out/staging/
scripts/Test-ComponentUpdates.ps1 scheduled runs: has any component released since the newest MSI?
scripts/New-InstallerImages.ps1   regenerates installer/assets/ artwork
installer/ComponentSuite.wixproj  WiX SDK project (built with `dotnet build`)
installer/Package.wxs             product, features, shortcuts, custom actions
installer/assets/                 icon, banner and dialog images
```

## Pipeline setup

No secrets are needed while the component repos are public. Release zips download without signing in, and the workflow passes its own built-in token only to get a higher GitHub API rate limit.

1. Make sure every component repo has at least one published (non-pre-release) release. Push a `v*.*.*` tag in that repo.
2. Push this repo to `main`. The **Build MSI** workflow uploads `ComponentSuite-<version>`, which contains the `.msi` and `build-info.json`, as a run artifact. The run summary lists the release tag and commit each component came from.

If a component repo is ever made **private**, create a fine-grained personal access token with **Contents: read** on it, add it as a repository secret, and set the fetch step's `GITHUB_TOKEN` to that secret.

### Triggers

Every **successful** build, except a pull request, is published automatically as a GitHub Release with the MSI (`ComponentSuite-<version>.msi`) attached and a table of component versions as release notes. The tag `v<version>` is created for you, so there's no need to tag by hand. If any step fails, nothing is released.

| Trigger | Version | Released? |
|---|---|---|
| push to `main` | `1.1.<run number>` | yes, tag `v1.1.<run number>` is created |
| pull request to `main` | `1.1.<run number>` | no, build only |
| tag `v1.2.3` pushed by hand | `1.2.3` | yes, under that tag |
| **Run workflow** (manual) | input, or `1.1.<run number>` | yes. With `allow_missing` ticked and a component left out, it's marked as a pre-release |
| `repository_dispatch` `component-built` | `1.1.<run number>` | yes. Lets a component repo trigger a rebuild after it releases |
| **daily schedule**, 06:00 UTC | `1.1.<run number>` | only if a component has a newer release than the newest MSI contains |

### Daily scheduled check

Component repos release on their own whenever they're pushed to `main`, and this repo picks those releases up automatically once a day. A small `check` job (`scripts/Test-ComponentUpdates.ps1`) reads the component tags listed in the newest ComponentSuite release's notes and compares them with each component's current release (or its pinned `tag` in `artifacts.json`). The MSI is built and released only if something changed, or if no ComponentSuite release exists yet. On quiet days the run stops after the check, and its summary shows the comparison table. For a new MSI straight away, use **Run workflow**.

GitHub pauses scheduled workflows in a public repository after 60 days without any commits. It emails a warning first, and you can turn the schedule back on from the Actions tab. Scheduled runs can also start a little later than 06:00 when GitHub is busy.

Versions always go up with the run number, so each MSI upgrades the previous install. To move to a new major/minor version, change `VERSION_PREFIX` at the top of `.github/workflows/build-msi.yml`, e.g. to `"2.0"`. Pipeline artifacts are also uploaded for every run, pull requests included, and are kept for 90 days.

To rebuild the MSI automatically whenever a component publishes a release, add a step like this after the release step in that component's workflow. It needs a token there with **Contents: write** on this repo:

```yaml
- run: gh api repos/<owner>/<this-repo>/dispatches -f event_type=component-built
  env:
    GH_TOKEN: ${{ secrets.INSTALLER_DISPATCH_TOKEN }}
```

### Missing releases

The pipeline fails if a component has no published release, or its release has no `<Repo>-<tag>-x64.zip`. This keeps an MSI from shipping without a component nobody noticed was missing. To build anyway, start this workflow manually with `allow_missing` ticked: the missing feature is left out and named in the run summary.

## Building locally

You need Windows and the .NET SDK 6 or later. WiX is restored from NuGet automatically.

```powershell
.\build.ps1 -Version 1.0.0            # -> out\msi\ComponentSuite.msi
```

No token is needed. If you hit GitHub's anonymous API rate limit (60 requests an hour), set `$env:GITHUB_TOKEN` to any GitHub token first.

| Option | Effect |
|---|---|
| `-SkipDownload` | Re-stage from `out\downloads\<id>\` without contacting GitHub. You can also put a release zip there yourself, unzipped. |
| `-AllowMissing` | Leave out components that have no release instead of failing. |
| `-SkipFetch` | Build from `out\staging\` exactly as it is. |

Override the product name, manufacturer or folder name with `dotnet build installer\ComponentSuite.wixproj -p:ProductName="..." -p:Manufacturer="..." -p:InstallFolderName="..."`. `InstallFolderName` (default `MyComponentSuite`) is used for both `C:\Program Files\<name>\` and the desktop shortcut folder.

## What the MSI does

* **Prerequisites:** setup stops if the Microsoft Visual C++ 2015-2022 Redistributable (x64) is missing. Selecting *Porting tools* also requires the x86 redistributable, because those binaries are 32-bit.
* **COM registration:** registers the Porting COM bridge (`COMServer.exe /RegServer` and `regsvr32 COMServerPS.dll`) on install, and unregisters it on uninstall.
* **Write access:** grants *Users* modify rights on `Application-Framework\` and `MfcSqLite\`, because FeatureTour writes its log and MfcSqliteApp its database next to the exe.
* **Shortcuts:** adds shortcuts for DiskForge, MFC SQLite Demo, PortAssist, Genie and the Localisation SDI/Dialog apps, both in the Start menu and in a `MyComponentSuite` folder on the Public desktop (visible to every user). Each appears only if its feature is installed, and both are removed on uninstall.
* **Traceability:** installs `build-info.json`, which records the repo, release tag, commit and file list behind each component.
* **Upgrades:** installing a newer version replaces the old one. Downgrades are blocked.

## Adding a component

1. Give the new repo a release job that publishes `<Repo>-<tag>-x64.zip` on `v*.*.*` tags (copy one from an existing component), and tag a release.
2. Add an entry to `artifacts.json`. In `from`, `*` matches one path segment and `**` any depth. A `to` that is empty or ends in `/` is a folder; anything else renames the single matching file.
3. Add its id to `StagedComponent` in `installer/ComponentSuite.wixproj`.
4. In `installer/Package.wxs`, add a `<Directory>` under `INSTALLFOLDER` and an `<?ifdef Has<Id> ?>` feature using `<Files Include="$(StagingDir)<Id>\**" .../>`.
