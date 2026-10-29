## Release Checklist

- [ ] Open PR from `dev` to `main` (make sure `main` is merged into `dev`)
- [ ] PR title follows format: `Release vX.X.X`
- [ ] Ensure `NEWS.md` is up to date with version and changes
- [ ] Package version updated using `usethis::use_version()`
- [ ] All tests are passing
- [ ] Documentation is up to date
- [ ] All CI checks are green

## Summary of Changes

<!--
Use additions to `NEWS.md` (between versions) as the description below.
Copy the changes from the NEWS.md file here.
-->

### New Features

-

### Bug Fixes

-

### Breaking Changes

-

### Documentation Updates

-

## Post-Release Actions

- [ ] After merge, verify GitHub Pages site updates correctly
- [ ] Verify release is created automatically with correct version tag
- [ ] Update any downstream packages that depend on this one

## Additional Notes

<!--
Add any additional release-specific notes here.
-->
