/*
 * mmforge_occt_shim.cpp — C++ implementation of the OCCT bridge
 *
 * Uses the official STEPCAFControl_Reader API (verified against OCCT 7.9):
 *   - ReadFile(path)              — parse STEP file
 *   - Transfer(doc)               — transfer into XDE document
 *   - XCAFDoc_ShapeTool           — extract shapes and labels
 *
 * No global state.  All resources owned by ReaderWrapper.
 * transfer_roots() creates a fresh XDE document on each call,
 * so repeated read+transfer cycles produce clean results.
 *
 * Build: see CMakeLists.txt in this directory.
 */

#include "mmforge_occt_shim.h"

#include <new>
#include <string>
#include <unordered_map>
#include <vector>

// --- OCCT headers ---
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>
#include <BRep_Tool.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Interface_Check.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Version.hxx>
#include <IGESCAFControl_Reader.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <TCollection_AsciiString.hxx>
#include <TCollection_HAsciiString.hxx>
#include <TDF_Label.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <Transfer_Binder.hxx>
#include <Transfer_TransientProcess.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XSControl_TransferReader.hxx>
#include <XSControl_WorkSession.hxx>
#include <XCAFDoc_ShapeTool.hxx>

// ======================================================================
// Internal types
// ======================================================================

namespace {

struct ShapeHash {
    size_t operator()(const TopoDS_Shape& s) const noexcept {
        auto h1 = std::hash<const void*>{}(s.TShape().get());
        // TopLoc_Location::HashCode() takes no argument in OCCT 7.9.
        auto h2 = std::hash<size_t>{}(s.Location().HashCode());
        return h1 ^ (h2 << 1);
    }
};

struct ShapeEq {
    bool operator()(const TopoDS_Shape& a,
                    const TopoDS_Shape& b) const noexcept {
        return a.IsSame(b);
    }
};

using LabelMap = std::unordered_map<TopoDS_Shape, std::string,
                                    ShapeHash, ShapeEq>;

/**
 * Internal state for one STEP reader session.
 *
 * Lifecycle:
 *   new → read_file → transfer_roots → get_root/shape_* → free
 *
 * transfer_roots() creates a fresh XDE document on each call and
 * clears previous roots/warnings/labels, so repeated read+transfer
 * cycles produce clean results.
 */
	struct ReaderWrapper {
	    // OCCT objects.
	    STEPCAFControl_Reader     caf;    // by value — not a transient
	    Handle(TDocStd_Document)  doc;    // rebuilt on each transfer
	    Handle(XCAFDoc_ShapeTool) st;    // rebuilt on each transfer

	    // Transfer results — rebuilt on each transfer_roots() call.
	    std::vector<TopoDS_Shape> roots;
	    std::vector<std::string>  warnings;
	    LabelMap                  labels;

	    // XDE assembly tree — rebuilt on each transfer_roots() call.
	    // name_store holds the name strings (index-aligned with tree_nodes).
	    // shape_store holds leaf TopoDS_Shape handles.
	    // tree_nodes[].name / .shape point into these — stable because
	    // the vectors are never modified after tree build completes.
	    std::vector<MmfTreeNode>  tree_nodes;
	    std::vector<std::string>  name_store;
	    std::vector<TopoDS_Shape> shape_store;
	};

/**
 * Tessellated mesh data.
 *
 * Owned by the opaque MmfMesh handle.  positions/normals/indices
 * are flat arrays; bbox is computed from the vertex positions.
 */
struct MeshData {
    std::vector<float> positions;  // [vertex_count * 3]
    std::vector<float> normals;    // [vertex_count * 3]
    std::vector<int>   indices;    // [triangle_count * 3]
    MmfOcctBBox        bbox;
};

MmfOcctShapeType mapShapeType(TopAbs_ShapeEnum t) noexcept {
    switch (t) {
        case TopAbs_COMPOUND:  return MMF_COMPOUND;
        case TopAbs_COMPSOLID: return MMF_COMPSOLID;
        case TopAbs_SOLID:     return MMF_SOLID;
        case TopAbs_SHELL:     return MMF_SHELL;
        case TopAbs_FACE:      return MMF_FACE;
        case TopAbs_WIRE:      return MMF_WIRE;
        case TopAbs_EDGE:      return MMF_EDGE;
        case TopAbs_VERTEX:    return MMF_VERTEX;
        default:               return MMF_UNKNOWN;
    }
}

void collectLabels(const Handle(XCAFDoc_ShapeTool)& st,
                   const TDF_Label& label,
                   LabelMap& out) {
    if (!st->IsShape(label))
        return;

    TopoDS_Shape shape = st->GetShape(label);
    if (shape.IsNull())
        return;

    Handle(TDataStd_Name) nameAttr;
    if (label.FindAttribute(TDataStd_Name::GetID(), nameAttr)) {
        TCollection_AsciiString ascii(nameAttr->Get(), '?');
        std::string name(ascii.ToCString());
        if (!name.empty())
            out[shape] = name;
    }

    TDF_LabelSequence subs;
    st->GetSubShapes(label, subs);
    for (Standard_Integer i = 1; i <= subs.Length(); ++i)
        collectLabels(st, subs.Value(i), out);
}

void buildLabelMap(const Handle(XCAFDoc_ShapeTool)& st,
                   LabelMap& out) {
    TDF_LabelSequence freeShapes;
    st->GetFreeShapes(freeShapes);
    for (Standard_Integer i = 1; i <= freeShapes.Length(); ++i)
        collectLabels(st, freeShapes.Value(i), out);
}

const char* lookupLabel(const ReaderWrapper* w,
                        const TopoDS_Shape* shape) {
    if (!w || !shape)
        return nullptr;
    auto it = w->labels.find(*shape);
    if (it == w->labels.end())
        return nullptr;
    return it->second.c_str();
}

// ---------------------------------------------------------------------------
// XDE Assembly Tree Builder
// ---------------------------------------------------------------------------

/// Extract a null-terminated name from a TDF_Label using TDataStd_Name.
static std::string extractName(const Handle(XCAFDoc_ShapeTool)& st,
                               const TDF_Label& label) {
    (void)st;  // unused — name comes from TDataStd_Name on the label
    Handle(TDataStd_Name) nameAttr;
    if (label.FindAttribute(TDataStd_Name::GetID(), nameAttr)) {
        TCollection_AsciiString ascii(nameAttr->Get(), '?');
        std::string s(ascii.ToCString());
        if (!s.empty())
            return s;
    }
    return "";
}

/// Fill a 16-element double array with a 4×4 column-major matrix
/// representing the given TopLoc_Location.  Identity if location is identity.
static void extractLocationMatrix(const TopLoc_Location& loc,
                                  double out[16]) {
    for (int i = 0; i < 16; ++i) out[i] = 0.0;
    out[0] = out[5] = out[10] = out[15] = 1.0;

    if (loc.IsIdentity())
        return;

    gp_Trsf trsf = loc.Transformation();
    // gp_Trsf::Value(row 1-3, col 1-4) → column-major 4×4
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 4; ++c) {
            out[c * 4 + r] = trsf.Value(r + 1, c + 1);
        }
    }
}

/// Compute the bounding box of a TopoDS_Shape.
static MmfOcctBBox computeBBox(const TopoDS_Shape& shape) {
    MmfOcctBBox b = {0,0,0, 0,0,0};
    if (shape.IsNull()) return b;
    Bnd_Box box;
    BRepBndLib::Add(shape, box);
    if (!box.IsVoid()) {
        Standard_Real xn, yn, zn, xx, yx, zx;
        box.Get(xn, yn, zn, xx, yx, zx);
        b.min_x = xn; b.min_y = yn; b.min_z = zn;
        b.max_x = xx; b.max_y = yx; b.max_z = zx;
    }
    return b;
}

/// Recursively build XDE assembly tree nodes (pass 1 — collect data).
/// parent_index: -1 for document root.
/// Stores raw data in separate vectors; pointers are fixed up in pass 2.
static void buildNodeRecursive(
    const Handle(XCAFDoc_ShapeTool)& st,
    const TDF_Label& label,
    int parent_index,
    std::vector<MmfTreeNode>&  tree_nodes,
    std::vector<std::string>&  name_store,
    std::vector<TopoDS_Shape>& shape_store)
{
    if (!st->IsShape(label))
        return;

    Standard_Boolean isAsm = st->IsAssembly(label);
    bool is_assembly = (isAsm == Standard_True);

    // Get the shape.
    TopoDS_Shape shape;
    if (is_assembly) {
        shape = st->GetShape(label);
    } else {
        if (!st->GetReferredShape(label, shape))
            shape = st->GetShape(label);
    }

    // Metadata.
    std::string name = extractName(st, label);
    MmfOcctShapeType type = mapShapeType(shape.ShapeType());

    TopLoc_Location loc;
    double location[16];
    if (!is_assembly)
        st->GetLocation(label, loc);
    extractLocationMatrix(loc, location);

    MmfOcctBBox bbox = {0,0,0, 0,0,0};
    if (!is_assembly && !shape.IsNull()) {
        bbox = computeBBox(shape);
    }

    // Create node (name and shape pointers will be fixed in pass 2).
    MmfTreeNode node;
    node.parent_index = parent_index;
    node.name = nullptr;
    node.type = type;
    node.bbox = bbox;
    node.is_assembly = is_assembly ? 1 : 0;
    node.shape = nullptr;
    for (int i = 0; i < 16; ++i) node.location[i] = location[i];

    int node_idx = static_cast<int>(tree_nodes.size());
    tree_nodes.push_back(node);
    name_store.push_back(name);

    if (!is_assembly && !shape.IsNull()) {
        shape_store.push_back(shape);
    }

    // Recurse into sub-components.
    if (is_assembly) {
        TDF_LabelSequence components;
        st->GetComponents(label, components);
        for (Standard_Integer i = 1; i <= components.Length(); ++i) {
            buildNodeRecursive(st, components.Value(i), node_idx,
                               tree_nodes, name_store, shape_store);
        }
    }
}

/// Build the XDE assembly tree starting from free shapes.
/// After this call, tree_nodes[].name and tree_nodes[].shape are valid
/// pointers into name_store / shape_store (which must not be modified further).
static void buildAssemblyTree(
    const Handle(XCAFDoc_ShapeTool)& st,
    std::vector<MmfTreeNode>&  tree_nodes,
    std::vector<std::string>&  name_store,
    std::vector<TopoDS_Shape>& shape_store)
{
    tree_nodes.clear();
    name_store.clear();
    shape_store.clear();

    TDF_LabelSequence freeShapes;
    st->GetFreeShapes(freeShapes);
    if (freeShapes.Length() == 0)
        return;

    // Determine if we have a real root assembly or need a synthetic one.
    bool hasRealRoot = (freeShapes.Length() == 1) &&
                       (st->IsAssembly(freeShapes.Value(1)) == Standard_True);

    if (hasRealRoot) {
        buildNodeRecursive(st, freeShapes.Value(1), -1,
                           tree_nodes, name_store, shape_store);
    } else {
        // Synthetic root.
        MmfTreeNode root;
        root.parent_index = -1;
        root.name = nullptr;
        root.type = MMF_COMPOUND;
        root.bbox.min_x = root.bbox.max_x = 0.0;
        root.bbox.min_y = root.bbox.max_y = 0.0;
        root.bbox.min_z = root.bbox.max_z = 0.0;
        root.is_assembly = 1;
        root.shape = nullptr;
        for (int i = 0; i < 16; ++i) root.location[i] = 0.0;
        root.location[0] = root.location[5] = root.location[10] = root.location[15] = 1.0;

        int rootIdx = static_cast<int>(tree_nodes.size());
        tree_nodes.push_back(root);
        name_store.push_back("Assembly");

        for (Standard_Integer i = 1; i <= freeShapes.Length(); ++i) {
            buildNodeRecursive(st, freeShapes.Value(i), rootIdx,
                               tree_nodes, name_store, shape_store);
        }
    }

    // --- Pass 2: fix up pointers and compute assembly bboxes ---

    // 2a. Set name pointers (name_store entries never move after this point).
    for (size_t i = 0; i < tree_nodes.size(); ++i) {
        tree_nodes[i].name = name_store[i].c_str();
    }

    // 2b. Set shape pointers for leaf nodes.
    size_t shape_idx = 0;
    for (size_t i = 0; i < tree_nodes.size(); ++i) {
        if (!tree_nodes[i].is_assembly) {
            tree_nodes[i].shape =
                reinterpret_cast<const MmfShape*>(&shape_store[shape_idx]);
            ++shape_idx;
        }
    }

    // 2c. Compute assembly bounding boxes (bottom-up: children before parents).
    // tree_nodes is in pre-order, so iterate backwards for bottom-up.
    for (int i = static_cast<int>(tree_nodes.size()) - 1; i >= 0; --i) {
        if (!tree_nodes[static_cast<size_t>(i)].is_assembly)
            continue;

        Bnd_Box unionBox;
        for (size_t j = static_cast<size_t>(i) + 1; j < tree_nodes.size(); ++j) {
            if (tree_nodes[j].parent_index == i) {
                Bnd_Box cb;
                cb.Update(tree_nodes[j].bbox.min_x,
                          tree_nodes[j].bbox.min_y,
                          tree_nodes[j].bbox.min_z,
                          tree_nodes[j].bbox.max_x,
                          tree_nodes[j].bbox.max_y,
                          tree_nodes[j].bbox.max_z);
                unionBox.Add(cb);
            }
        }
        if (!unionBox.IsVoid()) {
            Standard_Real xn, yn, zn, xx, yx, zx;
            unionBox.Get(xn, yn, zn, xx, yx, zx);
            tree_nodes[static_cast<size_t>(i)].bbox.min_x = xn;
            tree_nodes[static_cast<size_t>(i)].bbox.min_y = yn;
            tree_nodes[static_cast<size_t>(i)].bbox.min_z = zn;
            tree_nodes[static_cast<size_t>(i)].bbox.max_x = xx;
            tree_nodes[static_cast<size_t>(i)].bbox.max_y = yx;
            tree_nodes[static_cast<size_t>(i)].bbox.max_z = zx;
        }
    }
}

/**
 * Internal state for one IGES reader session.
 *
 * Same lifecycle as STEP: new → read_file → transfer_roots → shape_* → free.
 */
	struct IgesReaderWrapper {
	    IGESCAFControl_Reader     caf;
	    Handle(TDocStd_Document)  doc;
	    Handle(XCAFDoc_ShapeTool) st;

	    std::vector<TopoDS_Shape> roots;
	    std::vector<std::string>  warnings;
	    LabelMap                  labels;

	    // XDE assembly tree.
	    std::vector<MmfTreeNode>  tree_nodes;
	    std::vector<std::string>  name_store;
	    std::vector<TopoDS_Shape> shape_store;
	};

/// Lookup label in an IGES reader's label map.
const char* lookupIgesLabel(const IgesReaderWrapper* w,
                            const TopoDS_Shape* shape) {
    if (!w || !shape)
        return nullptr;
    auto it = w->labels.find(*shape);
    if (it == w->labels.end())
        return nullptr;
    return it->second.c_str();
}

} // anonymous namespace

// ======================================================================
// C ABI version
// ======================================================================

extern "C" {

int mmforge_abi_version(void) {
    return MMFORGE_SHIM_ABI_VERSION;
}

// ======================================================================
// STEP reader functions
// ======================================================================

MmfStepReader* mmforge_step_reader_new(void) {
    try {
        auto* w = new (std::nothrow) ReaderWrapper();
        if (!w) return nullptr;

        // Document is created fresh in transfer_roots().
        return reinterpret_cast<MmfStepReader*>(w);
    } catch (...) {
        return nullptr;
    }
}

MmfOcctError mmforge_step_reader_read_file(MmfStepReader* reader,
                                           const char* path) {
    if (!reader || !path)
        return MMF_NULL_ARGUMENT;

    auto* w = reinterpret_cast<ReaderWrapper*>(reader);

    try {
        // STEPCAFControl_Reader::ReadFile() delegates to the internal
        // STEPControl_Reader.  Returns IFSelect_RetDone on success.
        IFSelect_ReturnStatus status = w->caf.ReadFile(path);

        switch (status) {
            case IFSelect_RetDone: return MMF_OK;
            case IFSelect_RetVoid:
            case IFSelect_RetError:
            case IFSelect_RetFail: return MMF_PARSE_ERROR;
            case IFSelect_RetStop: return MMF_IO_ERROR;
            default:               return MMF_INTERNAL_ERROR;
        }
    } catch (...) {
        return MMF_INTERNAL_ERROR;
    }
}

MmfOcctError mmforge_step_reader_transfer_roots(MmfStepReader* reader) {
    if (!reader)
        return MMF_NULL_ARGUMENT;

    auto* w = reinterpret_cast<ReaderWrapper*>(reader);

    try {
        // Clear previous transfer results.
        w->roots.clear();
        w->warnings.clear();
        w->labels.clear();

        // Create a fresh XDE document for this transfer.
        // This ensures no stale state from a previous transfer cycle.
        // The old document is released by Handle ref-counting.
        w->doc = new TDocStd_Document("XmlXCAF");
        w->st  = XCAFDoc_DocumentTool::ShapeTool(w->doc->Main());

        // STEPCAFControl_Reader::Transfer(doc) transfers all STEP
        // entities into the XDE document.
        Standard_Boolean ok = w->caf.Transfer(w->doc);
        if (!ok)
            return MMF_TRANSFER_ERROR;

        // Collect transfer warnings.
        // STEPCAFControl_Reader::Reader() returns const STEPControl_Reader&
        // (STEPControl_Reader inherits XSControl_Reader which has WS()).
        const STEPControl_Reader& stepReader = w->caf.Reader();
        Handle(Transfer_TransientProcess) tp =
            stepReader.WS()->TransferReader()->TransientProcess();
        if (!tp.IsNull()) {
            Standard_Integer nbMapped = tp->NbMapped();
            for (Standard_Integer i = 1; i <= nbMapped; ++i) {
                Handle(Transfer_Binder) binder = tp->MapItem(i);
                if (binder.IsNull()) continue;
                Handle(Interface_Check) check = binder->Check();
                if (check.IsNull() || !check->HasWarnings()) continue;
                for (Standard_Integer j = 1; j <= check->NbWarnings(); ++j) {
                    Handle(TCollection_HAsciiString) msg = check->Warning(j);
                    if (!msg.IsNull())
                        w->warnings.emplace_back(msg->ToCString());
                }
            }
        }

        // Collect root shapes from the XCAF shape tool.
        TDF_LabelSequence free;
        w->st->GetFreeShapes(free);
        w->roots.reserve(free.Length());
        for (Standard_Integer i = 1; i <= free.Length(); ++i) {
            TopoDS_Shape s = w->st->GetShape(free.Value(i));
            if (!s.IsNull())
                w->roots.push_back(s);
        }

        // Build label map from XCAF metadata.
        buildLabelMap(w->st, w->labels);

        // Build XDE assembly tree for product-structure extraction.
        w->tree_nodes.clear();
        w->name_store.clear();
        w->shape_store.clear();
        buildAssemblyTree(w->st, w->tree_nodes, w->name_store, w->shape_store);

        return MMF_OK;
    } catch (...) {
        return MMF_INTERNAL_ERROR;
    }
}

int mmforge_step_reader_root_count(const MmfStepReader* reader) {
    if (!reader) return 0;
    auto* w = reinterpret_cast<ReaderWrapper*>(
        const_cast<MmfStepReader*>(reader));
    return static_cast<int>(w->roots.size());
}

const MmfShape* mmforge_step_reader_get_root(const MmfStepReader* reader,
                                             int index) {
    if (!reader) return nullptr;
    auto* w = reinterpret_cast<ReaderWrapper*>(
        const_cast<MmfStepReader*>(reader));
    if (index < 0 || static_cast<size_t>(index) >= w->roots.size())
        return nullptr;
    return reinterpret_cast<const MmfShape*>(&w->roots[index]);
}

int mmforge_step_reader_warning_count(const MmfStepReader* reader) {
    if (!reader) return 0;
    auto* w = reinterpret_cast<ReaderWrapper*>(
        const_cast<MmfStepReader*>(reader));
    return static_cast<int>(w->warnings.size());
}

const char* mmforge_step_reader_get_warning(const MmfStepReader* reader,
                                            int index) {
    if (!reader) return nullptr;
    auto* w = reinterpret_cast<ReaderWrapper*>(
        const_cast<MmfStepReader*>(reader));
    if (index < 0 || static_cast<size_t>(index) >= w->warnings.size())
        return nullptr;
    return w->warnings[index].c_str();
}

void mmforge_step_reader_free(MmfStepReader* reader) {
    if (!reader) return;
    delete reinterpret_cast<ReaderWrapper*>(reader);
}

// ======================================================================
// IGES reader functions
// ======================================================================

MmfIgesReader* mmforge_iges_reader_new(void) {
    try {
        auto* w = new (std::nothrow) IgesReaderWrapper();
        if (!w) return nullptr;
        return reinterpret_cast<MmfIgesReader*>(w);
    } catch (...) {
        return nullptr;
    }
}

MmfOcctError mmforge_iges_reader_read_file(MmfIgesReader* reader,
                                            const char* path) {
    if (!reader || !path)
        return MMF_NULL_ARGUMENT;

    auto* w = reinterpret_cast<IgesReaderWrapper*>(reader);

    try {
        IFSelect_ReturnStatus status = w->caf.ReadFile(path);

        switch (status) {
            case IFSelect_RetDone: return MMF_OK;
            case IFSelect_RetVoid:
            case IFSelect_RetError:
            case IFSelect_RetFail: return MMF_PARSE_ERROR;
            case IFSelect_RetStop: return MMF_IO_ERROR;
            default:               return MMF_INTERNAL_ERROR;
        }
    } catch (...) {
        return MMF_INTERNAL_ERROR;
    }
}

MmfOcctError mmforge_iges_reader_transfer_roots(MmfIgesReader* reader) {
    if (!reader)
        return MMF_NULL_ARGUMENT;

    auto* w = reinterpret_cast<IgesReaderWrapper*>(reader);

    try {
        w->roots.clear();
        w->warnings.clear();
        w->labels.clear();

        w->doc = new TDocStd_Document("XmlXCAF");
        w->st  = XCAFDoc_DocumentTool::ShapeTool(w->doc->Main());

        Standard_Boolean ok = w->caf.Transfer(w->doc);
        if (!ok)
            return MMF_TRANSFER_ERROR;

        // Collect transfer warnings via WorkSession.
        Handle(XSControl_WorkSession) ws = w->caf.WS();
        if (!ws.IsNull()) {
            Handle(Transfer_TransientProcess) tp =
                ws->TransferReader()->TransientProcess();
            if (!tp.IsNull()) {
                Standard_Integer nbMapped = tp->NbMapped();
                for (Standard_Integer i = 1; i <= nbMapped; ++i) {
                    Handle(Transfer_Binder) binder = tp->MapItem(i);
                    if (binder.IsNull()) continue;
                    Handle(Interface_Check) check = binder->Check();
                    if (check.IsNull() || !check->HasWarnings()) continue;
                    for (Standard_Integer j = 1; j <= check->NbWarnings(); ++j) {
                        Handle(TCollection_HAsciiString) msg = check->Warning(j);
                        if (!msg.IsNull())
                            w->warnings.emplace_back(msg->ToCString());
                    }
                }
            }
        }

        // Collect root shapes.
        TDF_LabelSequence free;
        w->st->GetFreeShapes(free);
        w->roots.reserve(free.Length());
        for (Standard_Integer i = 1; i <= free.Length(); ++i) {
            TopoDS_Shape s = w->st->GetShape(free.Value(i));
            if (!s.IsNull())
                w->roots.push_back(s);
        }

        buildLabelMap(w->st, w->labels);

        // Build XDE assembly tree.
        w->tree_nodes.clear();
        w->name_store.clear();
        w->shape_store.clear();
        buildAssemblyTree(w->st, w->tree_nodes, w->name_store, w->shape_store);

        return MMF_OK;
    } catch (...) {
        return MMF_INTERNAL_ERROR;
    }
}

int mmforge_iges_reader_root_count(const MmfIgesReader* reader) {
    if (!reader) return 0;
    auto* w = reinterpret_cast<IgesReaderWrapper*>(
        const_cast<MmfIgesReader*>(reader));
    return static_cast<int>(w->roots.size());
}

const MmfShape* mmforge_iges_reader_get_root(const MmfIgesReader* reader,
                                              int index) {
    if (!reader) return nullptr;
    auto* w = reinterpret_cast<IgesReaderWrapper*>(
        const_cast<MmfIgesReader*>(reader));
    if (index < 0 || static_cast<size_t>(index) >= w->roots.size())
        return nullptr;
    return reinterpret_cast<const MmfShape*>(&w->roots[index]);
}

int mmforge_iges_reader_warning_count(const MmfIgesReader* reader) {
    if (!reader) return 0;
    auto* w = reinterpret_cast<IgesReaderWrapper*>(
        const_cast<MmfIgesReader*>(reader));
    return static_cast<int>(w->warnings.size());
}

const char* mmforge_iges_reader_get_warning(const MmfIgesReader* reader,
                                             int index) {
    if (!reader) return nullptr;
    auto* w = reinterpret_cast<IgesReaderWrapper*>(
        const_cast<MmfIgesReader*>(reader));
    if (index < 0 || static_cast<size_t>(index) >= w->warnings.size())
        return nullptr;
    return w->warnings[index].c_str();
}

void mmforge_iges_reader_free(MmfIgesReader* reader) {
    if (!reader) return;
    delete reinterpret_cast<IgesReaderWrapper*>(reader);
}

// ======================================================================
// IGES shape functions (delegate to same internal logic as STEP)
// ======================================================================

MmfOcctShapeType mmforge_iges_shape_type(const MmfIgesReader* /*reader*/,
                                          const MmfShape* shape) {
    if (!shape) return MMF_UNKNOWN;
    auto* s = reinterpret_cast<const TopoDS_Shape*>(shape);
    return mapShapeType(s->ShapeType());
}

MmfOcctError mmforge_iges_shape_bbox(const MmfIgesReader* /*reader*/,
                                      const MmfShape* shape,
                                      MmfOcctBBox* out) {
    if (!shape || !out)
        return MMF_NULL_ARGUMENT;
    auto* s = reinterpret_cast<const TopoDS_Shape*>(shape);
    try {
        Bnd_Box box;
        BRepBndLib::Add(*s, box);
        if (box.IsVoid())
            return MMF_INTERNAL_ERROR;
        Standard_Real xn, yn, zn, xx, yx, zx;
        box.Get(xn, yn, zn, xx, yx, zx);
        out->min_x = xn;  out->min_y = yn;  out->min_z = zn;
        out->max_x = xx;  out->max_y = yx;  out->max_z = zx;
        return MMF_OK;
    } catch (...) {
        return MMF_INTERNAL_ERROR;
    }
}

const char* mmforge_iges_shape_label(const MmfIgesReader* reader,
                                      const MmfShape* shape) {
    if (!reader || !shape) return nullptr;
    auto* w = reinterpret_cast<IgesReaderWrapper*>(
        const_cast<MmfIgesReader*>(reader));
    auto* s = reinterpret_cast<const TopoDS_Shape*>(shape);
    return lookupIgesLabel(w, s);
}

// ======================================================================
// Shape functions (reader-scoped, no global state)
// ======================================================================

MmfOcctShapeType mmforge_shape_type(const MmfStepReader* /*reader*/,
                                    const MmfShape* shape) {
    if (!shape) return MMF_UNKNOWN;
    auto* s = reinterpret_cast<const TopoDS_Shape*>(shape);
    return mapShapeType(s->ShapeType());
}

MmfOcctError mmforge_shape_bbox(const MmfStepReader* /*reader*/,
                                const MmfShape* shape,
                                MmfOcctBBox* out) {
    if (!shape || !out)
        return MMF_NULL_ARGUMENT;

    auto* s = reinterpret_cast<const TopoDS_Shape*>(shape);

    try {
        Bnd_Box box;
        BRepBndLib::Add(*s, box);
        if (box.IsVoid())
            return MMF_INTERNAL_ERROR;

        Standard_Real xn, yn, zn, xx, yx, zx;
        box.Get(xn, yn, zn, xx, yx, zx);

        out->min_x = xn;  out->min_y = yn;  out->min_z = zn;
        out->max_x = xx;  out->max_y = yx;  out->max_z = zx;
        return MMF_OK;
    } catch (...) {
        return MMF_INTERNAL_ERROR;
    }
}

const char* mmforge_shape_label(const MmfStepReader* reader,
                                const MmfShape* shape) {
    if (!reader || !shape) return nullptr;
    auto* w = reinterpret_cast<ReaderWrapper*>(
        const_cast<MmfStepReader*>(reader));
    auto* s = reinterpret_cast<const TopoDS_Shape*>(shape);
    return lookupLabel(w, s);
}

void mmforge_shape_free(MmfShape* /*shape*/) {
    // No-op: shapes are owned by the reader's roots vector.
}

// ======================================================================
// XDE Assembly Tree Enumeration
// ======================================================================

int mmforge_shape_tree_node_count(const MmfStepReader* reader) {
    if (!reader) return 0;
    auto* w = reinterpret_cast<ReaderWrapper*>(
        const_cast<MmfStepReader*>(reader));
    return static_cast<int>(w->tree_nodes.size());
}

const MmfTreeNode* mmforge_shape_get_tree_node(
    const MmfStepReader* reader, int index)
{
    if (!reader) return nullptr;
    auto* w = reinterpret_cast<ReaderWrapper*>(
        const_cast<MmfStepReader*>(reader));
    if (index < 0 || static_cast<size_t>(index) >= w->tree_nodes.size())
        return nullptr;
    return &w->tree_nodes[static_cast<size_t>(index)];
}

int mmforge_iges_shape_tree_node_count(const MmfIgesReader* reader) {
    if (!reader) return 0;
    auto* w = reinterpret_cast<IgesReaderWrapper*>(
        const_cast<MmfIgesReader*>(reader));
    return static_cast<int>(w->tree_nodes.size());
}

const MmfTreeNode* mmforge_iges_shape_get_tree_node(
    const MmfIgesReader* reader, int index)
{
    if (!reader) return nullptr;
    auto* w = reinterpret_cast<IgesReaderWrapper*>(
        const_cast<MmfIgesReader*>(reader));
    if (index < 0 || static_cast<size_t>(index) >= w->tree_nodes.size())
        return nullptr;
    return &w->tree_nodes[static_cast<size_t>(index)];
}

// ======================================================================
// Tessellation
// ======================================================================

MmfOcctError mmforge_tessellate_shape(
    const MmfStepReader* /*reader*/,
    const MmfShape* shape,
    double linear_deflection,
    MmfMesh** out_mesh)
{
    if (!shape || !out_mesh)
        return MMF_NULL_ARGUMENT;

    auto* s = const_cast<TopoDS_Shape*>(
        reinterpret_cast<const TopoDS_Shape*>(shape));

    try {
        // 1. Generate triangulation.
        BRepMesh_IncrementalMesh mesher(*s, linear_deflection);
        if (!mesher.IsDone())
            return MMF_INTERNAL_ERROR;

        auto* mesh = new (std::nothrow) MeshData();
        if (!mesh)
            return MMF_INTERNAL_ERROR;

        // 2. Iterate over all faces.
        for (TopExp_Explorer exp(*s, TopAbs_FACE); exp.More(); exp.Next()) {
            TopoDS_Face face = TopoDS::Face(exp.Current());
            TopLoc_Location loc;
            Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
            if (tri.IsNull())
                continue;  // Skip faces with no triangulation.

            const int vertexOffset =
                static_cast<int>(mesh->positions.size() / 3);

            // Compute the transform for this face's location.
            gp_Trsf trsf;
            if (!loc.IsIdentity())
                trsf = loc.Transformation();

            // 3. Extract vertices.
            const int nbNodes = tri->NbNodes();
            for (int i = 1; i <= nbNodes; ++i) {
                gp_Pnt p = tri->Node(i);
                if (!loc.IsIdentity())
                    p.Transform(trsf);
                mesh->positions.push_back(static_cast<float>(p.X()));
                mesh->positions.push_back(static_cast<float>(p.Y()));
                mesh->positions.push_back(static_cast<float>(p.Z()));
            }

            // 4. Extract normals (or compute face normal as fallback).
            if (tri->HasNormals()) {
                for (int i = 1; i <= nbNodes; ++i) {
                    gp_Dir n = tri->Normal(i);
                    mesh->normals.push_back(static_cast<float>(n.X()));
                    mesh->normals.push_back(static_cast<float>(n.Y()));
                    mesh->normals.push_back(static_cast<float>(n.Z()));
                }
            } else {
                // Fallback: compute a face-level normal via cross product
                // of first triangle, or (0,0,1) if degenerate.
                float nx = 0.f, ny = 0.f, nz = 1.f;
                if (tri->NbTriangles() >= 1 && nbNodes >= 3) {
                    gp_Pnt p0 = tri->Node(1);
                    gp_Pnt p1 = tri->Node(2);
                    gp_Pnt p2 = tri->Node(3);
                    if (!loc.IsIdentity()) {
                        p0.Transform(trsf);
                        p1.Transform(trsf);
                        p2.Transform(trsf);
                    }
                    float ax = static_cast<float>(p1.X() - p0.X());
                    float ay = static_cast<float>(p1.Y() - p0.Y());
                    float az = static_cast<float>(p1.Z() - p0.Z());
                    float bx = static_cast<float>(p2.X() - p0.X());
                    float by = static_cast<float>(p2.Y() - p0.Y());
                    float bz = static_cast<float>(p2.Z() - p0.Z());
                    nx = ay * bz - az * by;
                    ny = az * bx - ax * bz;
                    nz = ax * by - ay * bx;
                    float len = std::sqrt(nx * nx + ny * ny + nz * nz);
                    if (len > 1e-12f) {
                        nx /= len;  ny /= len;  nz /= len;
                    } else {
                        nx = 0.f;  ny = 0.f;  nz = 1.f;
                    }
                }
                for (int i = 0; i < nbNodes; ++i) {
                    mesh->normals.push_back(nx);
                    mesh->normals.push_back(ny);
                    mesh->normals.push_back(nz);
                }
            }

            // 5. Extract triangle indices (OCCT is 1-based → 0-based).
            const int nbTris = tri->NbTriangles();
            for (int i = 1; i <= nbTris; ++i) {
                Standard_Integer n1, n2, n3;
                tri->Triangle(i).Get(n1, n2, n3);

                // Orient faces correctly: reverse winding if face is reversed.
                if (face.Orientation() == TopAbs_REVERSED) {
                    mesh->indices.push_back(vertexOffset + n1 - 1);
                    mesh->indices.push_back(vertexOffset + n3 - 1);
                    mesh->indices.push_back(vertexOffset + n2 - 1);
                } else {
                    mesh->indices.push_back(vertexOffset + n1 - 1);
                    mesh->indices.push_back(vertexOffset + n2 - 1);
                    mesh->indices.push_back(vertexOffset + n3 - 1);
                }
            }
        }

        // 6. Compute bounding box from positions.
        if (!mesh->positions.empty()) {
            float minX = mesh->positions[0], maxX = mesh->positions[0];
            float minY = mesh->positions[1], maxY = mesh->positions[1];
            float minZ = mesh->positions[2], maxZ = mesh->positions[2];
            for (size_t i = 3; i < mesh->positions.size(); i += 3) {
                float x = mesh->positions[i];
                float y = mesh->positions[i + 1];
                float z = mesh->positions[i + 2];
                if (x < minX) minX = x;  if (x > maxX) maxX = x;
                if (y < minY) minY = y;  if (y > maxY) maxY = y;
                if (z < minZ) minZ = z;  if (z > maxZ) maxZ = z;
            }
            mesh->bbox.min_x = static_cast<double>(minX);
            mesh->bbox.min_y = static_cast<double>(minY);
            mesh->bbox.min_z = static_cast<double>(minZ);
            mesh->bbox.max_x = static_cast<double>(maxX);
            mesh->bbox.max_y = static_cast<double>(maxY);
            mesh->bbox.max_z = static_cast<double>(maxZ);
        }

        *out_mesh = reinterpret_cast<MmfMesh*>(mesh);
        return MMF_OK;
    } catch (...) {
        return MMF_INTERNAL_ERROR;
    }
}

int mmforge_mesh_vertex_count(const MmfMesh* mesh) {
    if (!mesh) return 0;
    auto* m = reinterpret_cast<const MeshData*>(mesh);
    return static_cast<int>(m->positions.size() / 3);
}

int mmforge_mesh_triangle_count(const MmfMesh* mesh) {
    if (!mesh) return 0;
    auto* m = reinterpret_cast<const MeshData*>(mesh);
    return static_cast<int>(m->indices.size() / 3);
}

const float* mmforge_mesh_positions(const MmfMesh* mesh) {
    if (!mesh) return nullptr;
    auto* m = reinterpret_cast<const MeshData*>(mesh);
    return m->positions.data();
}

const float* mmforge_mesh_normals(const MmfMesh* mesh) {
    if (!mesh) return nullptr;
    auto* m = reinterpret_cast<const MeshData*>(mesh);
    return m->normals.data();
}

const int* mmforge_mesh_indices(const MmfMesh* mesh) {
    if (!mesh) return nullptr;
    auto* m = reinterpret_cast<const MeshData*>(mesh);
    return m->indices.data();
}

MmfOcctError mmforge_mesh_bbox(const MmfMesh* mesh, MmfOcctBBox* out_bbox) {
    if (!mesh || !out_bbox)
        return MMF_NULL_ARGUMENT;
    auto* m = reinterpret_cast<const MeshData*>(mesh);
    if (m->positions.empty())
        return MMF_INTERNAL_ERROR;
    *out_bbox = m->bbox;
    return MMF_OK;
}

void mmforge_mesh_free(MmfMesh* mesh) {
    if (!mesh) return;
    delete reinterpret_cast<MeshData*>(mesh);
}

// ======================================================================
// Version
// ======================================================================

const char* mmforge_occt_version(void) {
    return OCC_VERSION_COMPLETE;
}

} // extern "C"
