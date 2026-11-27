# MILKISHOP Android v1.5 release checklist

- Version: 1.5 (versionCode 6)
- Package: com.milki.shop
- Storefront: bundled app/src/main/assets/index.html
- Release signing: GitHub Actions secrets; never commit keystore material.
- Automated checks: static website validation, Android debug build, disposable PostgreSQL delivery-worker smoke test.
- Required before public release: latest signed release APK build and apksigner verification; install/update test on a physical Android device; sign-in/session, catalog, cart, order history, seller dashboard, admin dashboard, product image upload, payment receipt upload, external link and back navigation checks.
- Backend release gate: validate all pending Supabase migrations against a separate non-production Supabase project with the full schema and test Auth/RLS/Storage.
- Production safety: do not apply pending migrations or run test orders/payments against production.
