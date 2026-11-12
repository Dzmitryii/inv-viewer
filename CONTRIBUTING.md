# Contributing

INV Viewer is written in Swift and AppKit, with Metal for 3D rendering and OpenJPEG for JPEG 2000 decoding. Please open an issue before starting a large feature or changing the architecture.

## Development

```sh
bash scripts/bootstrap-openjpeg.sh
bash build.sh --verify
```

For changes to decoding, geometry or stored data, add a regression fixture that reproduces the problem. Use synthetic scans. Update both English and Russian strings when changing the interface.

UI, GPU and MCP changes also need testing in the running app. The [release checklist](RELEASING.md) describes those checks. In a pull request, explain what changes for the user and list the tests you ran, including the Mac and macOS version for native checks.

## Reports and sample data

Compatibility reports should include the scanner/export settings, viewer version, macOS version and chip. Use the compatibility issue form.

Keep patient scans, clinical screenshots, app-container files, identifiers and credentials out of issues and pull requests. The bundled demo has [separate media terms](docs/assets/NOTICE.md); use generated fixtures for new tests.

[Places to start](docs/contributing-tasks.md) · [Compatibility](docs/compatibility.md) · [Security reports](SECURITY.md)
