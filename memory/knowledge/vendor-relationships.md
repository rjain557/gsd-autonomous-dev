# Vendor Relationships Registry

PMAgent reads this to track every external vendor relationship that gates a
platform capability. Status updates are appended; per-vendor history lives
inline.

## Schema

Each vendor is a section with frontmatter-style fields. PMAgent reads
loosely — keep fields consistent so parsing works.

```
## <Vendor Name>
- capability: what this vendor enables
- status: not-started | in-progress | active | lapsed | archived
- technijian_poc: RJain or named officer
- vendor_poc: name + email at the vendor (when known)
- application_submitted: YYYY-MM-DD or n/a
- last_activity: YYYY-MM-DD
- next_action: who does what
- next_action_owner: pm-agent | legal-agent | security-agent | rjain
- next_action_due: YYYY-MM-DD or rolling
- renewal_date: YYYY-MM-DD (if applicable)
- notes: free-form history
```

---

## Apple — MDM Vendor Account (Apple Push Notification certificate)
- capability: MDM plugin for iOS (Edge MdmIos)
- status: not-started
- technijian_poc: RJain
- vendor_poc: (TBD — Apple SE assigned upon application)
- application_submitted: n/a (per §11 q4: start week-1 — submit by 2026-06-08)
- last_activity: 2026-06-01 (registered as week-1 action item)
- next_action: Submit application via business.apple.com + verify D-U-N-S
- next_action_owner: rjain
- next_action_due: 2026-06-08
- renewal_date: annual (TBD post-grant)
- notes: 3-6 month vendor process. Per myJian §10.9.

## Google — Android Enterprise EMM Partner
- capability: MDM plugin for Android (Edge MdmAndroid)
- status: not-started
- technijian_poc: RJain
- vendor_poc: (TBD)
- application_submitted: n/a
- last_activity: 2026-06-01
- next_action: Submit Android EMM partner application
- next_action_owner: rjain
- next_action_due: 2026-06-08
- renewal_date: continuous
- notes: 2-4 month vendor process.

## Samsung — Knox Partner
- capability: Knox-specific MDM features for Samsung devices
- status: not-started
- technijian_poc: RJain
- vendor_poc: (TBD)
- application_submitted: n/a
- last_activity: 2026-06-01
- next_action: Submit Knox partner application
- next_action_owner: rjain
- next_action_due: 2026-06-15
- renewal_date: continuous
- notes: 2-3 month vendor process.

## DigiCert (or Sectigo) — EV Code-Signing HSM
- capability: signing release binaries with EV cert in HSM
- status: not-started
- technijian_poc: RJain (signatory) + future security engineer
- vendor_poc: (TBD)
- application_submitted: n/a
- last_activity: 2026-06-01
- next_action: Request EV cert + procure FIPS 140-2/3 HSM (YubiHSM 2 / Thales Luna candidates)
- next_action_owner: rjain
- next_action_due: 2026-07-01
- renewal_date: 1-3 years
- notes: Phone verification with vendor SE; named signatory required (RJain).

## Cyera / Cisco Secure Endpoint / CrowdStrike — AV Vendor Allow-Listing
- capability: Edge agent not flagged as malware by 3rd-party AV products
- status: not-started
- technijian_poc: future security engineer (per §10.15) or PMAgent + RJain
- vendor_poc: (per-vendor)
- application_submitted: n/a
- last_activity: 2026-06-01
- next_action: Identify which AV vendors customers run; submit allow-list per-vendor
- next_action_owner: pm-agent
- next_action_due: 2026-07-15
- renewal_date: per-vendor (typically annual)
- notes: Vendor submission process usually 4-12 weeks each.

## ME-EC (ManageEngine Endpoint Central) — Existing Vendor (Cutover Target)
- capability: Patch management (current); Edge PatchManager will replace
- status: active
- technijian_poc: RJain
- vendor_poc: (existing relationship)
- application_submitted: n/a (existing)
- last_activity: 2026-04 (subscription renewed for 12 months)
- next_action: Monitor renewal date; prepare cutover plan
- next_action_owner: pm-agent
- next_action_due: 2027-03-01 (60 days pre-cutover)
- renewal_date: 2027-04 (current 12-month sub expires)
- notes: Per §11 q6 — single fleet cutover at end of current subscription. NO per-client renewal tracking needed.

## Teramind — Not Engaged
- capability: User activity monitoring (Edge UserActivity replaces)
- status: archived
- technijian_poc: n/a
- vendor_poc: n/a
- last_activity: 2026-06-01
- next_action: No active relationship; no client uses Teramind today (per §11 q5)
- next_action_owner: n/a
- notes: Per §11 q5 — no exit work needed. Forward-looking legal templates are the only artifact.

## (Future) FedRAMP — PMO Sponsorship
- capability: FedRAMP authorization for Edge platform (if/when federal customers signed)
- status: not-started
- technijian_poc: RJain + designated FedRAMP POC (TBD)
- vendor_poc: (sponsoring agency CIO/CISO)
- application_submitted: n/a
- last_activity: n/a
- next_action: Identify first federal-adjacent customer + sponsoring agency
- next_action_owner: rjain
- renewal_date: 3-year ATO cycle
- notes: 12-24 month process. Not on critical path until first federal customer.

## (Future) StateRAMP — Per-state authorization
- capability: StateRAMP authorization for state government customers
- status: not-started
- technijian_poc: RJain + designated state POC
- vendor_poc: (per-state)
- application_submitted: n/a
- next_action: Identify first state-government customer + state PoC
- next_action_owner: rjain
- notes: 9-18 months per state.

---

## Update log

- 2026-06-01: initial population from myJian §10.9 calendar-time tracks + §11 decisions
