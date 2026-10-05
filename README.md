# Set-CanadianLanguage

PowerShell script that switches a Windows 11 PC from en-US to French (Canada) with English (Canada) as the second language and the Canadian Multilingual Standard keyboard. Designed to be run as SYSTEM from an RMM (e.g. NinjaOne) on PCs with no Active Directory or Intune, but works from any elevated session.

## How it works

- Installs the fr-CA and en-CA language packs, then checks every language feature (spell check, handwriting, OCR, speech, text-to-speech) and installs any that are missing.
- Temporarily allows on-demand content from Windows Update if WSUS policies block it, and restores the original policies afterwards, including after a run killed by a timeout.
- Blocks Windows from cleaning up the installed language packs later.
- Sets the system display language, the non-Unicode system locale and the home location (Canada).
- Applies the language, regional formats and keyboard to the Welcome screen and to the template that new user profiles are created from.
- Applies the same settings to existing users: right away for the signed-in user, and at next sign-in for everyone else (Active Setup). The display language is written straight into each profile so it changes on the next sign-in.
- Sets Chrome and Edge spell check to French and English through policy, since browsers ignore the Windows spell checker.
- Checks the end result and reports anything still wrong.
- Does **not** reboot. A reboot is needed before the display language fully changes; schedule it separately.
- Logs to `C:\ProgramData\CanadianLanguage\provision.log`.

Re-running is safe. Once the language packs are present, a run takes a few minutes.

## Usage

NinjaOne settings: Run As = System, 64-bit, timeout of at least 120 minutes. Installing fr-CA alone can take about 45 minutes on a clean device.

The defaults need no parameters. To change them, pass parameters on the command line (NinjaOne: script parameters field):

| Parameter                     | Default                    | Purpose                                                  |
|-------------------------------|----------------------------|----------------------------------------------------------|
| `-PrimaryLanguage`            | `fr-CA`                    | Display language and regional formats                    |
| `-SecondaryLanguages`         | `en-CA`                    | Additional input languages                               |
| `-KeyboardLayoutId`           | `00011009`                 | Keyboard layout (Canadian Multilingual Standard)         |
| `-GeoId`                      | `39`                       | Home location (Canada)                                   |
| `-SetSystemLocale`            | `$true`                    | Set the non-Unicode system locale to the primary language |
| `-TimeZone`                   | (none)                     | Optional, e.g. `Eastern Standard Time`                   |
| `-ConfigureBrowsers`          | `$true`                    | Set Chrome and Edge spell check policies                 |
| `-BrowserSpellcheckLanguages` | `fr`, `en-CA`, `en-US`     | Chrome/Edge spell check languages                        |
| `-AuditOnly`                  | off                        | Report compliance only, change nothing                   |

Running manually from an elevated PowerShell:

```powershell
.\set-canadian-language.ps1
.\set-canadian-language.ps1 -AuditOnly
```

`-AuditOnly` exits 0 when the device is compliant and 1 when it is not, so it can be used as a condition for a NinjaOne automation.

## Results

The last line of output is one of:

| Output                                  | Meaning                                                     |
|-----------------------------------------|-------------------------------------------------------------|
| `SUCCESS\|PC\|...\|RebootRequired`      | Everything applied; reboot to finish                         |
| `SUCCESS\|PC\|...\|NoRebootNeeded`      | Already compliant, nothing changed                           |
| `PARTIAL\|PC\|n issue(s)\|...`          | Applied, but some checks still fail (listed as warnings above) |
| `FAILED\|PC\|fr-CA display pack missing`| The display language could not be installed (exit code 5)    |

Other exit codes: 2 = not running as administrator, 3 = language cmdlets not available, 4 = less than 4 GB free. If a language pack fails to install after three attempts, the script stops with an error.

If the NinjaOne custom fields `caLanguageStatus`, `caLanguageDetail` and `caLanguageChecked` exist, the result is written to them as well. They are optional.

## Troubleshooting

If `Install-Language` fails within seconds with error `-2147009295` (`0x80073CF1`, package not found), check for a pending servicing reboot:

```powershell
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
```

If it returns `True`, Windows is waiting for a restart to finish installing updates, which can block language installs. Restart the PC and run the script again. The script logs a warning when it detects this.

## Requirements

- Windows 11 (or Windows 10 20H2 and later)
- Administrator or SYSTEM privileges
- Access to Windows Update and about 4 GB of free disk space
