//! Typed identifiers — prevent mixing raw `u32` handles.

macro_rules! define_id {
    ($name:ident, $doc:expr) => {
        #[doc = $doc]
        #[derive(
            Debug,
            Clone,
            Copy,
            Default,
            PartialEq,
            Eq,
            Hash,
            PartialOrd,
            Ord,
            serde::Serialize,
            serde::Deserialize,
        )]
        pub struct $name(pub u32);

        impl $name {
            pub const ZERO: Self = Self(0);

            #[inline]
            pub fn new(value: u32) -> Self {
                Self(value)
            }

            #[inline]
            pub fn get(self) -> u32 {
                self.0
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(f, "{}({})", stringify!($name), self.0)
            }
        }
    };
}

define_id!(NodeId, "Identifies a node in the scene tree.");
define_id!(GeometryId, "Identifies a geometry entry in the model.");
define_id!(MaterialId, "Identifies a material definition.");
define_id!(TextureId, "Identifies a texture resource.");
define_id!(EntityId, "Identifies a 2D drawing entity.");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_ids_are_distinct() {
        let node = NodeId::new(1);
        let geom = GeometryId::new(1);
        // They hold the same raw value but are different types.
        assert_eq!(node.get(), geom.get());
        // Compile-time distinction: uncommenting below would fail.
        // let _: NodeId = geom;
    }

    #[test]
    fn display_id() {
        assert_eq!(NodeId::new(42).to_string(), "NodeId(42)");
    }

    #[test]
    fn zero_constant() {
        assert_eq!(NodeId::ZERO.get(), 0);
    }
}
