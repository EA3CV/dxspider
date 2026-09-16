# DXWeb Admin

## Purpose

DXWeb Admin is the SYSOP-only administration web. It is deliberately
separate from the normal User Web.

## Authentication and session behaviour

-   The login dialog is shown at startup.
-   Esc may close the dialog.
-   A permanent **Login** button remains available and reopens it.
-   After successful authentication the control becomes **Logout**
    (including the callsign where available).
-   Logout returns the control to Login.
-   Access requires authenticated DXUser privilege \>= 9.
-   A normal privilege-0 user is rejected.
-   On successful Login, displayed data from a previous Admin browser
    session is cleared before fresh data is loaded.

The administrative privilege belongs to the authenticated Admin context.
It must never be implemented by raising the technical `#WEB-n` channel
privilege.

## Main areas

### Operation

The Operation area contains the current operational receive/command
panels. The redundant Console button inside Operation has been removed.

### Registration

Pending, History and Search use the registration data supplied by
DXSpider.

History and Search columns:

`ID | Callsign | SSIDs | Status | Name | Email | Requested | Resolved | By | Note`

`By` and `Note` appear once. `Note` is rendered from the record's `note`
field.

SSID lists are compacted only for presentation. For example,
`[1,2,3,4,5]` is displayed as `1-5`.

## Network boundary

In the validated deployment DXSpider IntMsg listens on:

`127.0.0.1:27754`

This provides a network boundary in addition to the Admin
role/authorization checks. Do not make this listener generally reachable
merely to support a future remote User Web.
