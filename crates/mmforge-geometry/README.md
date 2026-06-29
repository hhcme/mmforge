# mmforge-geometry

Geometry types, B-Rep handles, tessellation adapter, and OCCT FFI for MMForge.

## Role

This crate bridges the core model to heavy geometry operations. It will hold the OpenCASCADE (OCCT) safe wrapper and tessellation pipeline.

## Current Status (Phase 0)

- `BRepHandle` placeholder for future OCCT integration
- `TessellationQuality` with deflection calculation
- Re-exports core geometry types

## Future (Phase 1+)

- OCCT `STEPControl_Reader` wrapper
- `TopoDS_Shape` safe handle with Drop strategy
- `BRepMesh_IncrementalMesh` tessellation adapter
- All `unsafe` FFI code confined to `occt/sys` or `occt/adapter`
