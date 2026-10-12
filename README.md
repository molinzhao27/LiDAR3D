# Facet: a cleanroom 3D scanner for iPhone and iPad

Facet is an independent, from-scratch take on the kind of app described at
[hege.sh](https://hege.sh/) (Heges 3D Scanner). It was written only from that
public product description: scan with the LiDAR or TrueDepth camera, preview in
3D and AR, export coloured PLY and STL, and get the files off the device over
Wi-Fi or the Files app, all processed on the device. No code, assets, names or
UI from Heges were used.

## What it does

| | |
|---|---|
| **LiDAR scan** (rear camera, Pro iPhones and iPads) | Walk around an object, person, car or room. ARKit tracks the phone; Facet fuses the LiDAR depth frames into a signed distance volume (down to 5 mm detail) for the mesh and into a coloured voxel cloud for the points. A distance limit crops the background. |
| **TrueDepth scan** (front FaceID camera) | Faces and small close-up objects. The subject holds still for about a second; 30 depth frames are averaged to cut noise, then meshed and coloured from the video frame. |
| **3D viewer** | Orbit, zoom and pan. Switch between mesh and point cloud, captured colour or shaded surface. |
| **AR viewer** | Place the scan on a real surface at true scale, pinch to scale, twist to rotate. |
| **Exports** | `*_mesh.ply` (binary, per-vertex colour, metres), `*_mesh.stl` (binary, millimetres for slicers), `*_points.ply` (dense coloured point cloud, LiDAR only). |
| **Getting files out** | Built-in Wi-Fi page (turn it on, open the shown `http://…:8080` address on a computer on the same network), the share sheet (AirDrop, Mail, Save to Files), the Files app, and Finder/iTunes file sharing. |
| **Privacy** | No network access except the opt-in local Wi-Fi page. No analytics, no accounts. |

## Build and run

You need a Mac with Xcode 16 and a device with LiDAR or FaceID (the simulator
has neither sensor, though it can open the viewer).

```sh
brew install xcodegen
cd LiDAR3D
xcodegen generate
open Facet3D.xcodeproj
```

In Xcode, select the **Facet3D** target, set your team under *Signing &
Capabilities* (and change the bundle id from `com.molinzhao.lidar3d` if Xcode
asks), pick your iPhone and press Run.

Run the core unit tests on any Mac (or Linux with Swift installed):

```sh
cd ScanCore && swift test
```

`.github/workflows/build.yml` runs both the tests and an unsigned device build
on GitHub's macOS runners, so pushing this folder to a repo checks it compiles.

## How it works

```
App/
  Capture/LiDARScanner.swift      ARKit session, depth fusion, ARMeshAnchor → Mesh
  Capture/TrueDepthScanner.swift  AVFoundation depth+video sync, frame averaging
  Views/                          SwiftUI screens, SceneKit viewer, ARSCNView placement
  Support/ScanStore.swift         Documents/<scan-id>/ folders, PLY/STL writing
  Support/WiFiShareServer.swift   Network.framework HTTP server (read-only, opt-in)
  Support/PixelSampling.swift     CVPixelBuffer readers (depth, confidence, YCbCr, BGRA)
ScanCore/                         Pure Swift, no Apple frameworks, unit-tested
  Geometry.swift                  Intrinsics, back-projection, rigid transforms
  Depth.swift                     Depth map → mesh, multi-frame depth averaging
  TSDF.swift                      Signed distance fusion, surface-nets mesh extraction
  VoxelCloud.swift                Sparse voxel fusion, mesh colouring and cropping
  Mesh.swift                      Indexed mesh, normals, filtering, small-piece removal
  PLY.swift, STL.swift            Readers and writers
  HTTP.swift                      Request parsing, routing, download page
```

**LiDAR pipeline.** About six times a second, the scene depth map (256×192) is
back-projected with the camera intrinsics, moved into world space with ARKit's
camera pose, and added to a sparse voxel grid (5 mm by default) that averages
position and colour per voxel; this is saved as the point cloud. Pixels on
silhouette edges, where the sensor blends foreground and background, are
skipped. The same frames are fused into a truncated signed distance volume
(sparse 8×8×8 blocks of voxels, each averaging its distance to the surface and
its colour over many frames). When you press Done, the surface is extracted
with surface nets, giving a smooth mesh at the voxel size, and tiny floating
pieces are removed. If fusion found no surface, ARKit's own coarser mesh is
coloured from the voxel cloud and used instead.

**TrueDepth pipeline.** Depth and video are synchronised, depth is averaged per
pixel over 30 frames with outlier rejection, and neighbouring pixels are joined
into triangles except across depth jumps (edges of the head, background).

## Known limits of this first version

- Not yet run on a device: this was written in an environment without Xcode, so
  expect a round of small fixes the first time it is built. The core logic is
  covered by unit tests.
- TrueDepth mode is a single-view capture (one side of a face), not a full 360°
  head. Fusing a head turning in front of the camera needs frame-to-frame
  alignment (ICP), which is the natural next step.
- The upright orientation of TrueDepth scans uses a fixed rotation
  (`TrueDepthScanner.portraitCorrection`); if scans appear on their side, adjust
  that one constant.
- LiDAR scans assume the subject holds still. Movement (or tracking drift) during a
  scan leaves a doubled "ghost" surface; there is no frame-to-frame alignment yet.
- No texture maps (UV-mapped images); colour is per vertex, like coloured PLY.
