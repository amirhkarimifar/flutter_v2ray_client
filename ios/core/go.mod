// Go module that produces Xray.xcframework for the iOS packet tunnel.
//
// The xray-core dependency is deliberately NOT pinned here: xray-core keeps the
// module path github.com/xtls/xray-core while tagging releases as v25.x / v26.x,
// so those tags are not resolvable as semver. CI resolves the release tag to its
// commit and runs `go get github.com/xtls/xray-core@<sha>`, which records a
// pseudo-version. See .github/workflows/build-ios-xcframework.yml.
module dev.amirzr/flutter_v2ray_client/xray

go 1.25
