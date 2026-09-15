# DXSpider Web 2.5.0 validation checklist

Release date: 2026-09-15

1. Compile `perl/Web.pm` in the real DXSpider environment.
2. Compile `dxweb/app.pl` with the installed Mojolicious.
3. Start DXSpider, then dxweb, and confirm `/healthz` reports `ready`.
4. Before login, confirm no feed/history is displayed and commands are unavailable.
5. Login with an existing no-password user when policy permits.
6. Login with an existing password user using the correct password.
7. Confirm the same user is rejected with a wrong password.
8. Confirm locked-out/non-user calls are rejected.
9. Confirm HUMAN, RBN, ANN, WWV, WCY and WX reach their separate views.
10. Run `w` and another harmless normal command and verify their DXSpider output in Console.
11. Verify Spot and ANN submission use the authenticated logical user and return their protocol result.
12. Execute `LOGIN -> w -> LOGOUT -> LOGIN same CALL -> w` repeatedly without restarting DXSpider, dxweb or the browser.
13. Repeat the login/logout/login cycle at least 10 times for closure validation.
14. During that test confirm `/healthz` keeps `ws_dropped=0` and `ws_slow_disconnects=0` for a normal browser.
15. Confirm HUMAN-only, RBN-only and combined Spots views keep identical fixed column geometry.
16. Confirm Source is the first Spots column and Comment has the largest width.
17. Confirm the Spots counter can exceed the bounded 1000-item in-memory spot list.
18. Verify a privileged command is rejected for a priv-0 session.
19. For a password-authenticated SYSOP, verify privileges are those allowed by normal DXSpider login semantics.
20. Connect a protocol-v1 external WebCluster and verify its external-auth model remains operational.
21. Repeat slow-browser/backpressure tests and confirm a slow browser cannot block or degrade DXSpider.
