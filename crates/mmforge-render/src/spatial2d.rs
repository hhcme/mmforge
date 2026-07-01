//! 2D spatial index for viewport culling.
//!
//! Uses a uniform grid to partition draw commands by their axis-aligned
//! bounding box.  Queries return only the command indices whose AABB
//! overlaps the requested viewport rect.

use mmforge_core::drawing::BBox2D;

use crate::draw2d::FlatDrawCommand;

/// Grid-based spatial index for 2D draw commands.
#[derive(Debug, Clone)]
pub struct SpatialIndex2D {
    /// World bounds of the indexed space.
    world_bounds: BBox2D,
    /// Number of cells per axis.
    grid_size: usize,
    /// Cell width and height.
    cell_w: f64,
    cell_h: f64,
    /// Flat grid: `cells[row * grid_size + col]` holds command indices.
    cells: Vec<Vec<u32>>,
}

impl SpatialIndex2D {
    /// Build a spatial index from a list of flat draw commands.
    ///
    /// `grid_size` is the number of cells per axis (e.g., 32 → 32×32 grid).
    pub fn build(commands: &[FlatDrawCommand], world_bounds: BBox2D, grid_size: usize) -> Self {
        let gw = world_bounds.width().max(1e-10);
        let gh = world_bounds.height().max(1e-10);
        let cell_w = gw / grid_size as f64;
        let cell_h = gh / grid_size as f64;
        let mut cells = vec![Vec::new(); grid_size * grid_size];

        for (idx, cmd) in commands.iter().enumerate() {
            let bbox = command_bbox(&cmd.cmd);
            if !bbox.is_valid() {
                continue;
            }

            // Clamp to world bounds.
            let cmin_x = bbox.min[0].max(world_bounds.min[0]);
            let cmin_y = bbox.min[1].max(world_bounds.min[1]);
            let cmax_x = bbox.max[0].min(world_bounds.max[0]);
            let cmax_y = bbox.max[1].min(world_bounds.max[1]);

            let col_min = ((cmin_x - world_bounds.min[0]) / cell_w).floor() as isize;
            let col_max = ((cmax_x - world_bounds.min[0]) / cell_w).floor() as isize;
            let row_min = ((cmin_y - world_bounds.min[1]) / cell_h).floor() as isize;
            let row_max = ((cmax_y - world_bounds.min[1]) / cell_h).floor() as isize;

            let gs = grid_size as isize;
            for row in row_min.max(0)..=row_max.min(gs - 1) {
                for col in col_min.max(0)..=col_max.min(gs - 1) {
                    cells[row as usize * grid_size + col as usize].push(idx as u32);
                }
            }
        }

        Self {
            world_bounds,
            grid_size,
            cell_w,
            cell_h,
            cells,
        }
    }

    /// Query for command indices whose AABB overlaps the given viewport rect.
    pub fn query(&self, viewport: BBox2D) -> Vec<u32> {
        if !viewport.is_valid() {
            return Vec::new();
        }

        // Clamp viewport to world bounds.
        let vmin_x = viewport.min[0].max(self.world_bounds.min[0]);
        let vmin_y = viewport.min[1].max(self.world_bounds.min[1]);
        let vmax_x = viewport.max[0].min(self.world_bounds.max[0]);
        let vmax_y = viewport.max[1].min(self.world_bounds.max[1]);

        let col_min = ((vmin_x - self.world_bounds.min[0]) / self.cell_w).floor() as isize;
        let col_max = ((vmax_x - self.world_bounds.min[0]) / self.cell_w).floor() as isize;
        let row_min = ((vmin_y - self.world_bounds.min[1]) / self.cell_h).floor() as isize;
        let row_max = ((vmax_y - self.world_bounds.min[1]) / self.cell_h).floor() as isize;

        let gs = self.grid_size as isize;
        let mut result = std::collections::HashSet::new();
        for row in row_min.max(0)..=row_max.min(gs - 1) {
            for col in col_min.max(0)..=col_max.min(gs - 1) {
                for &idx in &self.cells[row as usize * self.grid_size + col as usize] {
                    result.insert(idx);
                }
            }
        }

        let mut v: Vec<u32> = result.into_iter().collect();
        v.sort_unstable();
        v
    }

    /// Total number of indexed commands.
    pub fn len(&self) -> usize {
        self.cells.iter().map(|c| c.len()).sum()
    }

    /// Whether the index is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Compute a conservative AABB for a draw command.
fn command_bbox(cmd: &crate::draw2d::DrawCommand2D) -> BBox2D {
    use crate::draw2d::DrawCommand2D;
    let mut bbox = BBox2D::EMPTY;
    match cmd {
        DrawCommand2D::Line { start, end } => {
            bbox.extend_point(*start);
            bbox.extend_point(*end);
        }
        DrawCommand2D::Circle { center, radius } => {
            bbox.extend_point([center[0] - radius, center[1] - radius]);
            bbox.extend_point([center[0] + radius, center[1] + radius]);
        }
        DrawCommand2D::Arc { center, radius, .. } => {
            // Conservative: full circle bbox.
            bbox.extend_point([center[0] - radius, center[1] - radius]);
            bbox.extend_point([center[0] + radius, center[1] + radius]);
        }
        DrawCommand2D::Polyline { points, .. } => {
            for p in points {
                bbox.extend_point(*p);
            }
        }
        DrawCommand2D::Text {
            position, height, ..
        } => {
            bbox.extend_point(*position);
            bbox.extend_point([position[0] + height * 10.0, position[1] + *height]);
        }
    }
    bbox
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draw2d::DrawCommand2D;

    fn make_cmd(x0: f64, y0: f64, x1: f64, y1: f64) -> FlatDrawCommand {
        FlatDrawCommand {
            layer_index: 0,
            layer_name: "test".to_string(),
            cmd: DrawCommand2D::Line {
                start: [x0, y0],
                end: [x1, y1],
            },
            line_type: None,
            line_weight: None,
        }
    }

    #[test]
    fn empty_index() {
        let idx = SpatialIndex2D::build(
            &[],
            BBox2D {
                min: [0.0, 0.0],
                max: [10.0, 10.0],
            },
            4,
        );
        assert!(idx.is_empty());
        assert!(
            idx.query(BBox2D {
                min: [0.0, 0.0],
                max: [10.0, 10.0]
            })
            .is_empty()
        );
    }

    #[test]
    fn full_coverage_query() {
        let cmds = vec![
            make_cmd(0.0, 0.0, 1.0, 1.0),
            make_cmd(5.0, 5.0, 6.0, 6.0),
            make_cmd(9.0, 9.0, 10.0, 10.0),
        ];
        let idx = SpatialIndex2D::build(
            &cmds,
            BBox2D {
                min: [0.0, 0.0],
                max: [10.0, 10.0],
            },
            4,
        );
        let all = idx.query(BBox2D {
            min: [0.0, 0.0],
            max: [10.0, 10.0],
        });
        assert_eq!(all.len(), 3);
    }

    #[test]
    fn partial_culling() {
        let cmds = vec![
            make_cmd(0.0, 0.0, 1.0, 1.0),
            make_cmd(5.0, 5.0, 6.0, 6.0),
            make_cmd(9.0, 9.0, 10.0, 10.0),
        ];
        let idx = SpatialIndex2D::build(
            &cmds,
            BBox2D {
                min: [0.0, 0.0],
                max: [10.0, 10.0],
            },
            4,
        );
        // Query only the bottom-left quadrant.
        let partial = idx.query(BBox2D {
            min: [0.0, 0.0],
            max: [5.0, 5.0],
        });
        assert!(partial.contains(&0));
        // Command at (9,9) should not be in this query.
        assert!(!partial.contains(&2));
    }
}
