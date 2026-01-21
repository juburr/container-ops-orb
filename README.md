<div align="center">
  <img align="center" width="250" src="assets/logos/container-ops-orb-256px.png" alt="Container Ops Orb">
  <h1>Container Ops Orb</h1>
  <i>A CircleCI orb that simplifies building, signing, scanning, and publishing container images.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/container-ops-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/container-ops-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/container-ops-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/container-ops-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/container-ops-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

## Getting Started
The goal of this orb is to share jobs that allow users to easily perform the following operations:
- Create container image using `docker`, or distroless container images using `apko` and `melange`.
- Sign the container images using `cosign`.
- Publish the container images to a container registry such as `ghcr.io`.
- Scan the contents of container images using `syft` to produce SBOMs.
- Scan the container images for vulnerabilities using `grype`.
- Publish the signature and attach SBOMs and/or scan results as attestations.
