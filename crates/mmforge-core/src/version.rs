//! Package and runtime version information.

/// Current crate / runtime version.
pub const VERSION: Version = Version {
    major: 0,
    minor: 1,
    patch: 0,
    pre_release: None,
};

/// Semantic version triple with optional pre-release tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
    pub pre_release: Option<&'static str>,
}

impl Version {
    /// Returns `true` when `self` is API-compatible with `other`
    /// (same major version, following SemVer).
    pub fn is_compatible_with(&self, other: &Version) -> bool {
        self.major == other.major
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)?;
        if let Some(pre) = self.pre_release {
            write!(f, "-{pre}")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_version() {
        assert_eq!(VERSION.to_string(), "0.1.0");
    }

    #[test]
    fn compatibility_same_major() {
        let a = Version {
            major: 1,
            minor: 0,
            patch: 0,
            pre_release: None,
        };
        let b = Version {
            major: 1,
            minor: 5,
            patch: 3,
            pre_release: None,
        };
        assert!(a.is_compatible_with(&b));
    }

    #[test]
    fn incompatibility_different_major() {
        let a = Version {
            major: 1,
            minor: 0,
            patch: 0,
            pre_release: None,
        };
        let b = Version {
            major: 2,
            minor: 0,
            patch: 0,
            pre_release: None,
        };
        assert!(!a.is_compatible_with(&b));
    }
}
