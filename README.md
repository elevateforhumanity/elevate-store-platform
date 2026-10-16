# Elevate Store Platform

Standalone Store and customer website provisioning project. Reuses the previously README-only LMS backup repository; it is not a backup of the LMS.

## Database

Supabase project: elevate-store-production (`ebnbeqdsuxygopetptlv`), us-east-2.

`supabase/store-provisioning.sql` records the applied foundation and job migrations. All six tables enable RLS and revoke anon/authenticated access. Only the Store backend may access these tables. Existing Elevate authentication records remain untouched.

Customer identities are mapped by verified issuer and subject, because the Store and LMS have separate authentication databases. No credentials belong in resource tracking tables; use Secret Manager.

## Verified

Database transaction checks passed: pending subscriptions cannot enqueue jobs; active subscriptions without a verified payment event cannot enqueue; repeated enqueue returns the same job; a processing job cannot be claimed twice. Verification data was rolled back.

## Not live yet

The existing Store application has not been transferred into this repository. Payment webhook signature verification, provider project/repository creation workers, deployment configuration, admin controls, and end-to-end provisioning remain to be connected and tested. The database foundation does not create external resources by itself. No automatic customer charges or infrastructure creation have been enabled.
