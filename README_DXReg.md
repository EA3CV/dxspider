# DXSpider Registration V1

Native DXSpider user-registration workflow with historical request storage,
password handling and optional non-blocking email/Telegram notifications.

## Files

Install:

- `perl/DXReg.pm` -> `/spider/perl/DXReg.pm`
- `cmd/register/*.pl` -> `/spider/local_cmd/register/`
- `reg_templates/*` -> `/spider/local_data/reg_templates/`
- merge the required `DXVars.pm` settings from `DXVars.registration.example`
- apply `cluster.patch` to `perl/cluster.pl`

`registration.json` is created automatically on first use under:

    /spider/local_data/registration.json

The template directory and template files are NOT generated or overwritten by
DXReg. They are supplied with this package so that the SYSOP can customize them
without DXReg replacing local changes.

## Startup integration

`DXReg::init()` must run after `DXProt->init()` and before `scripts/startup`.

When:

    $reg_enable = 1;

DXReg forces:

    $reqreg    = 1;
    $passwdreq = 0;

When `$reg_enable = 0`, DXReg does not modify the normal DXSpider
`$reqreg` / `$passwdreq` configuration.

A module restart requires a DXSpider/node restart; `load/cmd` reloads command
files but does not reload `DXReg.pm`.

## Commands

### register/request

Normal user:

    register/request <email> <EN|ES> [ssid-list]

The CALL is always taken from the connected session.

SYSOP:

    register/request <call> <email> <EN|ES> [ssid-list]

Examples:

    register/request user@example.net ES
    register/request user@example.net EN 1,2,5
    register/request EA3XYZ user@example.net ES 1-5

Only one PENDING request per CALL is allowed. Previous ACCEPTED, REJECTED or
REMOVED records remain in history.

Valid SSIDs are 1..99. SSID 0 and zero-padded forms such as 01..09 are rejected.

### register/show

    register/show
    register/show <call>
    register/show <request-id>

Without arguments, lists PENDING requests.

With a CALL, shows the complete registration history for that CALL.

With an ID, shows that request using the same readable history format.

### register/accept

    register/accept <request-id|call> [note]

The CALL form resolves the unique PENDING request for that CALL.

Acceptance:

- preserves existing registered SSIDs;
- adds newly requested SSIDs;
- never interprets omitted SSIDs as removal;
- reuses the basecall password when one exists;
- otherwise generates a new password;
- synchronizes the same password across the basecall and all accepted/current SSIDs;
- stores `requested_ssids` and `accepted_ssids` separately in history;
- never stores the password in `registration.json` or debug logs.

### register/reject

    register/reject <request-id|call> [note]

Marks the PENDING request REJECTED and optionally stores an administrative note.
A later request for the same CALL creates a new historical record.

### register/remove

    register/remove <call> [note]

Acts on the basecall and every existing `CALL-1` .. `CALL-99` DXUser record:

- preserves the DXUser records;
- sets `registered=0`;
- removes the password;
- creates a historical `REMOVED` record with affected SSIDs;
- disconnects any affected connected sessions after persistence so that the next
  login loads the new state.

A disconnect failure is logged but does not roll back an already persisted
registration removal.

## Persistence

Registration workflow history is stored in:

    /spider/local_data/registration.json

The effective registered/password state remains in DXUser.

The JSON file stores administrative history only, including:

- ID
- CALL
- email
- language
- requested SSIDs
- accepted/affected SSIDs
- status
- source
- IP
- timestamps
- processed_by
- optional note

Passwords are never stored in the JSON file.

## Notifications

Notifications are optional.

New registration request:

- optional email to SYSOP
- optional Telegram message to SYSOP

Acceptance/rejection:

- optional email to the user

Email and Telegram do not block the DXSpider main loop:

- SMTP runs in `Mojo::IOLoop::Subprocess`
- Telegram uses asynchronous `Mojo::UserAgent`

Logs record notification states such as:

    queued
    sent
    failed

without logging passwords, SMTP credentials or Telegram tokens.

Templates are UTF-8. Email bodies use MIME UTF-8/Base64 and Telegram supports
HTML formatting in its templates.

## Dependencies

The tested installation provides:

- `Net::SMTP`
- `Net::SMTP::SSL`
- `Authen::SASL`
- `IO::Socket::SSL`
- `Mojo::UserAgent`
- normal CA certificates

Telegram does not require `curl`.

## Notes

`register/show`, `register/accept`, `register/reject` and `register/remove` are
SYSOP operations. `register/request` is shared between normal users and SYSOPs.

Registration operations are local to the node on which they are executed.
There is no automatic cross-node propagation in V1.
