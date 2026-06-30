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
#include <IFSelect_ReturnStatus.hxx>
#include <Interface_Check.hxx>
#include <Standard_Version.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <TCollection_AsciiString.hxx>
#include <TCollection_HAsciiString.hxx>
#include <TDF_Label.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <TopAbs_ShapeEnum.hxx>
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
// Version
// ======================================================================

const char* mmforge_occt_version(void) {
    return OCC_VERSION_COMPLETE;
}

} // extern "C"
