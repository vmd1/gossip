//! Minimal 2D geometry in the shared, y-down, point-based space the layout lives in.

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

impl Size {
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn from_origin(origin: Point, size: Size) -> Self {
        Self::new(origin.x, origin.y, size.width, size.height)
    }

    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    pub fn origin(&self) -> Point {
        Point::new(self.x, self.y)
    }

    /// Width and height of the overlap with `other`, or `None` when they do not overlap at all (touching edges
    /// give a zero extent, which callers compare against a tolerance).
    pub fn intersection_extent(&self, other: &Rect) -> Option<(f64, f64)> {
        let w = self.max_x().min(other.max_x()) - self.min_x().max(other.min_x());
        let h = self.max_y().min(other.max_y()) - self.min_y().max(other.min_y());
        (w >= 0.0 && h >= 0.0).then_some((w, h))
    }
}
