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
