## 2026-09-17 — 0.8.3 Delete dialog polish

- Delete DXUser base callsign input is now a compact 180px field.
- SYSOP note is laid out below its label and uses the available dialog width.
- Removed the redundant second browser confirmation: the explicit Delete DXUser
  dialog and red `Delete base + all SSIDs` action are the confirmation surface.

## 2026-09-17 — 0.8.2 corrective update

- Fixed Admin Registration decision UI: opening Reject now exposes only Reject;
  opening Accept exposes only Accept. The selected action is tracked and a
  mismatched response is rejected by the UI. A password is displayed only for
  an actual `reg_accept_result`.
- Registration History/Search columns are no longer crowded. The table is wider
  and horizontally scrollable, with comfortable cell padding and a 330px Note
  column.
- Fixed Admin command output spacing: the existing final-response helper is now
  actually called when `command_result.final` is true. Exactly one blank visual
  line is appended after each completed command response.

## 2026-09-17 — Registration language selector

- The public Registration dialog now includes a language selector; EN is the default.
- Registration requests send and persist the selected two-letter language code.
- DXReg accepts normalized two-letter language codes instead of restricting requests to EN/ES.
- Notification template lookup keeps the existing safe fallback: if the selected-language template does not exist, the matching English `.EN` template is used.

## 2026-09-17 — Registration delete + command output spacing

- Admin Registration adds **Delete user** for a base callsign.
- The operation deletes the base DXUser plus every existing BASE-SSID (1..99), refuses deletion while any affected callsign is connected, and records a permanent `DELETED` event in Registration History.
- Registration history itself is never deleted.
- User and Admin command outputs now add one visual blank line after the final response chunk.
- Registration History/Search use a more compact fixed-column layout so `Note` receives the remaining width.

# Changes --- closeout snapshot 0.7.0

## User Web

-   Added Anonymous state.
-   Anonymous receives C/R spots plus ANN, WWV, WCY and WX.
-   Anonymous can select C/R and clear receive windows.
-   Added visible Anonymous indicator.
-   Login-only actions are attenuated and explain the Login requirement.
-   Register remains available before Login.
-   Registration request can be submitted anonymously.
-   Password label clarifies its registered-user purpose.
-   Unified informational popup appearance.
-   Corrected popup stacking/clipping, including ANN Send.
-   Added SSID range input and compact consecutive-range presentation.
-   Preserved effective privilege 0 for normal Web User sessions.

## Admin Web

-   Separated Admin authentication/authorization from normal User Web.
-   Requires SYSOP privilege \>= 9.
-   Added permanent Login/Logout control.
-   Esc no longer leaves the user without a way to reopen Login.
-   Increased node/Administration heading prominence.
-   Clears previous displayed session content after successful Login.
-   Removed redundant Console button from Operation.
-   Corrected Registration History/Search columns.
-   Removed duplicate By/Note headers.
-   Added Note display.
-   Added compact SSID presentation.

## Operational/security

-   User and Admin use separate technical `#WEB-n` sessions.
-   `#WEB-n` remains a privilege-0 transport.
-   Local IntMsg boundary observed on 127.0.0.1:27754.
-   No requirement to restart DXSpider for UI-only changes.
