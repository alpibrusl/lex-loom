# Opportunity: E.164 phone-number normalization micro-API for solo developers

## Problem
Solo developers building sign-up, checkout, or support forms need to accept a user-submitted phone number and turn it into a single, canonical E.164 string (+CCNNN), but the realistic options today are either heavyweight (Twilio Lookup is a multi-product carrier-verification suite aimed at teams) or priced per 1,000 calls in tiers that are overkill for a 5?10k-call/month project. Open-source `libphonenumber` solves the parsing math but forces the developer to install, run, and maintain the library themselves, with no quota, auth, or hosting. The gap is a thin, single-call normalize endpoint with a sub-$1 pay-as-you-go tier and no per-seat minimum ? something a solo dev can wire into one form in an afternoon.

## Target user
Solo full-stack developer shipping a SaaS sign-up form (or a small agency build) in under 48 hours, who wants one POST request that returns a normalized E.164 string plus valid/invalid, on a free-or-sub-$1 plan with no account onboarding.

## Alternatives
| Alternative | What it does | Price / gap |
|---|---|---|
| Twilio Lookup API | Pay-as-you-go phone lookup/validation suite for teams (https://www.twilio.com/en-us/user-authentication-identity/pricing/lookup) | Pay-as-you-go but bundled into a large carrier-verification platform; no sub-$1 micro tier, heavier onboarding than a solo dev wants |
| Veriphone | Phone validation with carrier lookup, line-type detection, country ID (https://veriphone.io/pricing) | From $0.20 / 1,000 with monthly volume plans; feature-rich and quota-capped, still above a tiny sub-$1 use case |
| PhoneValidation API | Hard-caps at plan quota, returns 402 when exhausted, no overage (https://phonevalidationapi.com/pricing) | Quota-locked plans; no explicit sub-$1 / free micro tier for very low-volume solo traffic |
| Open-source libphonenumber (Google) | Self-host parsing/formatting/validation library (https://github.com/google/libphonenumber) | Free but zero hosting, auth, or quota ? the developer owns ops; this is the "DIY floor" a micro-API can monetise above |
| Botoi validation API | One-call E.164 parse/validate for 30+ countries, free tier included (https://botoi.com/blog/phone-number-validation-api/) | Closest competitor; proves demand but confirms a thin free/cheap tier already exists, narrowing differentiation |

## Implementation estimate
16 hours ? a single FastAPI process wrapping Python `phonenumbers` for the normalize/validate endpoint, plus Bearer-key auth, an in-memory/SQLite quota store, and a health check, fits one focused weekend; the parsing logic is provided by a battle-tested library, so the work is plumbing, auth, quota, and one integration test, not algorithm development.

## Dependencies
- Python `phonenumbers` port of google/libphonenumber for E.164 parsing, formatting, and validation (https://github.com/google/libphonenumber)
- A web-framework runtime (FastAPI, or stdlib `http.server`) to host the single endpoint
- A single VPS or FaaS instance under $5/mo for always-on hosting
- An in-memory or single-file SQLite store for per-key quota and Bearer-key issuance
- A reverse-proxy / HTTPS termination layer (e.g. managed FaaS or Caddy) for TLS and the public URL

## Sources
- https://www.twilio.com/en-us/user-authentication-identity/pricing/lookup
- https://veriphone.io/pricing
- https://phonevalidationapi.com/pricing
- https://github.com/google/libphonenumber
- https://botoi.com/blog/phone-number-validation-api/
- https://www.reachly.co/blogs/phone-validation-api-comparison

## Confidence
75 ? real demand is evidenced by a populated 2026 buyer's guide and multiple live paid providers, and the open-source layer proves the core math is solved; what holds it below 90 is the existence of Botoi's free/cheap tier and Twilio's reach, meaning differentiation depends entirely on execution of the sub-$1/zero-onboarding positioning rather than on an open whitespace gap.

## Recommendation
Build. The scope is a 16-hour single-endpoint service on a solved open-source library, so execution risk is low, and the searches confirm a live market of solo-dev-facing phone validators with no dominant sub-$1, zero-onboarding player. The one real risk is Botoi's already-shipping free/cheap tier, so the build should differentiate hard on price-per-call and onboarding speed and treat "free tier under $1 for <10k calls/month" as the wedge; if Botoi's free tier proves genuinely generous enough to absorb this segment, the differentiation collapses and confidence would drop below 50.
