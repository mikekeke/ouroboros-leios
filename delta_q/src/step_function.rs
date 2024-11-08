use itertools::Itertools;
use std::{
    cmp::Ordering,
    collections::BinaryHeap,
    fmt::{self, Write},
    iter::Peekable,
    str::FromStr,
    sync::Arc,
};

#[derive(Debug)]
pub enum StepFunctionError {
    InvalidFormat(&'static str, usize),
    InvalidDataRange,
    NonMonotonicData,
}

impl fmt::Display for StepFunctionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidFormat(s, pos) => write!(f, "invalid format: {} at position {}", s, pos),
            Self::InvalidDataRange => write!(f, "invalid data range"),
            Self::NonMonotonicData => write!(f, "non-monotonic data"),
        }
    }
}
impl std::error::Error for StepFunctionError {}

pub const DEFAULT_MAX_SIZE: usize = 10000;

/// A step function represented as a list of (x, y) pairs.
#[derive(Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(try_from = "StepFunctionSerial", into = "StepFunctionSerial")]
pub struct StepFunction {
    /// invariants: first component strictly monotonically increasing and non-negative,
    /// with neighbouring x values being separated by at least five ε
    data: Option<Arc<[(f32, f32)]>>,
    max_size: usize,
    mode: CompactionMode,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct StepFunctionSerial {
    data: Vec<(f32, f32)>,
}

impl StepFunction {
    pub fn zero() -> Self {
        Self::new(&[]).unwrap()
    }

    /// Create a step function CDF from a vector of (x, y) pairs.
    /// The x values must be greater than 0 and must be strictly monotonically increasing.
    /// The y values must be from (0, 1] and must be strictly monotonically increasing.
    pub fn new(points: &[(f32, f32)]) -> Result<Self, StepFunctionError> {
        if !points.iter().all(|&(x, y)| x >= 0.0 && y >= 0.0) {
            return Err(StepFunctionError::InvalidDataRange);
        }
        if !points.windows(2).all(|w| w[0].0 < w[1].0) {
            return Err(StepFunctionError::NonMonotonicData);
        }
        let data = if points.is_empty() {
            None
        } else {
            Some(points.into())
        };
        Ok(Self {
            data,
            max_size: DEFAULT_MAX_SIZE,
            mode: CompactionMode::default(),
        })
    }

    pub fn at(&self, x: f32) -> f32 {
        self.data()
            .iter()
            .rev()
            .find(|&&(x0, _)| x0 <= x)
            .map_or(self.data().last().map_or(0.0, |&(_x, y)| y), |&(_, y)| y)
    }

    pub fn integrate(&self, from: f32, to: f32) -> f32 {
        self.func_iter()
            .tuple_windows()
            .filter_map(|((x0, y), (x1, _y))| {
                let min = x0.max(from);
                let max = x1.min(to);
                if min < max {
                    Some((max - min) * y)
                } else {
                    None
                }
            })
            .sum()
    }

    pub fn compact(&self, mut data: Vec<(f32, f32)>) -> Result<Self, StepFunctionError> {
        compact(&mut data, self.mode, self.max_size);
        Self::new(&data)
    }

    /// Set the maximum size of the CDF using a mutable reference.
    pub fn set_max_size(&mut self, max_size: usize) {
        self.max_size = max_size;
    }

    /// Set the compaction mode of the CDF using a mutable reference.
    pub fn set_mode(&mut self, mode: CompactionMode) {
        self.mode = mode;
    }

    /// Set the maximum size of the CDF using builder pattern.
    pub fn with_max_size(mut self, max_size: usize) -> Self {
        self.max_size = max_size;
        self
    }

    /// Set the compaction mode of the CDF using builder pattern.
    pub fn with_mode(mut self, mode: CompactionMode) -> Self {
        self.mode = mode;
        self
    }

    pub fn data(&self) -> &[(f32, f32)] {
        static EMPTY: &[(f32, f32)] = &[];
        self.data.as_deref().unwrap_or(EMPTY)
    }

    pub fn iter(&self) -> StepFunctionIterator {
        StepFunctionIterator {
            cdf: self.data().iter(),
            prev: (0.0, 0.0),
            first: false,
            last: false,
        }
    }

    pub fn graph_iter(&self) -> StepFunctionIterator {
        StepFunctionIterator {
            cdf: self.data().iter(),
            prev: (0.0, 0.0),
            first: true,
            last: false,
        }
    }

    pub fn func_iter(&self) -> StepFunctionIterator {
        StepFunctionIterator {
            cdf: self.data().iter(),
            prev: (0.0, 0.0),
            first: true,
            last: true,
        }
    }

    /// Get the width of the CDF.
    pub fn max_x(&self) -> f32 {
        self.data().iter().next_back().map_or(0.0, |(x, _)| *x)
    }

    pub fn zip<'a>(
        &'a self,
        other: &'a StepFunction,
    ) -> impl Iterator<Item = (f32, (f32, f32))> + 'a {
        PairIterators::new(self.data().iter().copied(), other.data().iter().copied())
    }

    pub fn mult(&self, factor: f32) -> Self {
        if factor == 0.0 {
            return Self::new(&[])
                .unwrap()
                .with_max_size(self.max_size)
                .with_mode(self.mode);
        }
        Self {
            data: self
                .data
                .as_ref()
                .map(|d| d.iter().map(|&(x, y)| (x, y * factor)).collect()),
            max_size: self.max_size,
            mode: self.mode,
        }
    }

    pub fn add(&self, other: &Self) -> Self {
        let mut data = Vec::new();
        for (x, (l, r)) in self.zip(other) {
            data.push((x, l + r));
        }
        compact(&mut data, self.mode, self.max_size);
        Self {
            data: (!data.is_empty()).then_some(data.into()),
            max_size: self.max_size,
            mode: self.mode,
        }
    }

    pub fn choice(&self, my_fraction: f32, other: &Self) -> Self {
        let mut data = Vec::new();
        for (x, (l, r)) in self.zip(other) {
            data.push((x, l * my_fraction + r * (1.0 - my_fraction)));
        }
        compact(&mut data, self.mode, self.max_size);
        Self {
            data: (!data.is_empty()).then_some(data.into()),
            max_size: self.max_size,
            mode: self.mode,
        }
    }

    pub fn similar(&self, other: &Self) -> bool {
        fn similar(a: f32, b: f32) -> bool {
            a == 0.0 && b.abs() < 1e-6
                || b == 0.0 && a.abs() < 1e-6
                || (a - b).abs() / a.max(b) < 1e-6
        }
        self.data().len() == other.data().len()
            && self
                .data()
                .iter()
                .zip(other.data().iter())
                .all(|(a, b)| similar(a.0, b.0) && similar(a.1, b.1))
    }
}

impl From<StepFunction> for StepFunctionSerial {
    fn from(cdf: StepFunction) -> Self {
        Self {
            data: cdf.data()[..].to_owned(),
        }
    }
}

impl TryFrom<StepFunctionSerial> for StepFunction {
    type Error = StepFunctionError;

    fn try_from(serial: StepFunctionSerial) -> Result<Self, Self::Error> {
        StepFunction::new(&serial.data)
    }
}

impl fmt::Debug for StepFunction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StepFunction")
            .field("data", &self.data())
            .finish()
    }
}

impl fmt::Display for StepFunction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut scratch = String::new();

        write!(f, "[")?;
        for (i, (x, y)) in self.data().iter().enumerate() {
            if i > 0 {
                write!(f, ", ")?;
            }
            write!(&mut scratch, "{:.5}", x)?;
            write!(f, "({}, ", trim(&scratch))?;
            scratch.clear();
            write!(&mut scratch, "{:.5}", y)?;
            write!(f, "{})", trim(&scratch))?;
            scratch.clear();
        }
        write!(f, "]")?;
        Ok(())
    }
}

fn trim(s: &str) -> &str {
    s.trim_end_matches('0').trim_end_matches('.')
}

impl FromStr for StepFunction {
    type Err = StepFunctionError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        fn err(s: &'static str, x: &str, y: &str) -> StepFunctionError {
            StepFunctionError::InvalidFormat(s, x.as_ptr() as usize - y.as_ptr() as usize)
        }

        let mut data = Vec::new();
        let mut x_prev = -1.0;
        for (x, y) in s
            .trim()
            .trim_start_matches("[")
            .trim_end_matches("]")
            .split(',')
            .tuples()
        {
            let x = x.trim();
            if x.chars().next() != Some('(') {
                return Err(err("expecting '('", x, s));
            }
            let x: f32 = x[1..]
                .trim()
                .parse()
                .map_err(|_| err("expecting number", &x[1..], s))?;
            if x < 0.0 {
                return Err(StepFunctionError::InvalidDataRange);
            }
            if x <= x_prev {
                return Err(StepFunctionError::NonMonotonicData);
            }
            x_prev = x;
            let y = y.trim();
            if y.chars().next_back() != Some(')') {
                let pos = y.char_indices().next_back().map(|(i, _)| i).unwrap_or(0);
                return Err(err("expecting ')'", &y[pos..], s));
            }
            let y: f32 = y[..y.len() - 1]
                .trim()
                .parse()
                .map_err(|_| err("expecting number", y, s))?;
            if y < 0.0 {
                return Err(StepFunctionError::InvalidDataRange);
            }
            data.push((x, y));
        }
        Ok(Self {
            data: (!data.is_empty()).then_some(data.into()),
            max_size: DEFAULT_MAX_SIZE,
            mode: CompactionMode::default(),
        })
    }
}

pub struct StepFunctionIterator<'a> {
    cdf: std::slice::Iter<'a, (f32, f32)>,
    prev: (f32, f32),
    first: bool,
    last: bool,
}

impl<'a> Iterator for StepFunctionIterator<'a> {
    type Item = (f32, f32);

    fn next(&mut self) -> Option<Self::Item> {
        if self.first {
            self.first = false;
            Some((0.0, 0.0))
        } else if let Some(pair) = self.cdf.next() {
            self.prev = *pair;
            Some(*pair)
        } else if self.last {
            self.last = false;
            Some((f32::INFINITY, self.prev.1))
        } else {
            None
        }
    }
}

impl<'a> std::iter::FusedIterator for StepFunctionIterator<'a> {}

#[derive(Debug, PartialEq, Default, Clone, Copy, serde::Serialize, serde::Deserialize)]
pub enum CompactionMode {
    #[default]
    UnderApproximate,
    OverApproximate,
}

/// Repeated computation with a CDF can lead to an unbounded number of data points, hence we limit its size.
/// This function ensures a maximal data length of `max_size` points by collapsing point pairs that are closest to each other on the x axis.
/// Under CompactionMode::UnderApproximate, the new point gets the greater x coordinate while under CompactionMode::OverApproximate, the new point gets the smaller x coordinate.
/// The resulting point always has the higher y value of the pair.
fn compact(data: &mut Vec<(f32, f32)>, mode: CompactionMode, max_size: usize) {
    {
        let mut pos = 0;
        let mut prev_y = 0.0;
        let mut prev_x = -1.0;
        for i in 0..data.len() {
            let (x, y) = data[i];
            if y != prev_y {
                data[pos] = (x, y);
                prev_y = y;
                pos += 1;
            }
            if x == prev_x {
                web_sys::console::log_2(&"duplicate x".into(), &format!("{:?}", data).into());
                panic!("duplicate x");
            }
            prev_x = x;
        }
        data.truncate(pos);
    }

    if data.len() <= max_size {
        return;
    }
    // determine overall scale of the graph to determine the granularity of distances
    // (without this rounding the pruning will be dominated by floating point errors)
    let scale = data[data.len() - 1].0;
    let granularity = scale / 10000.0;

    #[derive(Debug, PartialEq)]
    struct D {
        bin: i16,
        idx: usize,
        dist: f32,
        use_left: bool,
    }
    impl Eq for D {}
    impl PartialOrd for D {
        fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
            Some(self.cmp(other))
        }
    }
    impl Ord for D {
        fn cmp(&self, other: &Self) -> Ordering {
            other
                .bin
                .cmp(&self.bin)
                .then_with(|| self.idx.cmp(&other.idx))
        }
    }
    let mk_d = |dist: f32, idx: usize, use_left: bool| D {
        bin: (dist / granularity) as i16,
        idx,
        dist,
        use_left,
    };

    // use a binary heap to pull the closest pairs, identifying them by their x coordinate and sorting them by the distance to their right neighbor.
    //
    // we only consider points whose left and right neighbor are in opposing quadrants (i.e. rising or falling graph around this location)
    let mut heap = data
        .iter()
        .tuple_windows::<(&(f32, f32), &(f32, f32), &(f32, f32))>()
        .enumerate()
        .filter_map(|(idx, (a, b, c))| {
            let use_left = if a.1 >= b.1 && b.1 >= c.1 {
                mode == CompactionMode::OverApproximate
            } else if a.1 <= b.1 && b.1 <= c.1 {
                mode == CompactionMode::UnderApproximate
            } else {
                return None;
            };
            let dist = if use_left { c.0 - b.0 } else { b.0 - a.0 };
            Some(mk_d(dist, idx + 1, use_left))
        })
        .collect::<BinaryHeap<_>>();

    let mut to_remove = data.len() - max_size;
    let mut last_bin = -1;
    while let Some(d) = heap.pop() {
        if d.bin == last_bin {
            last_bin = -1;
            continue;
        } else {
            last_bin = d.bin;
        }
        // skip points that have already been removed
        if data[d.idx].1 < 0.0 {
            continue;
        }

        // just remove this point, meaning that the left neighbour needs to be updated
        let mut neighbours = data[..d.idx]
            .iter()
            .enumerate()
            .rev()
            .filter_map(|(i, (_x, y))| (*y >= 0.0).then_some(i));

        if let Some(neighbour) = neighbours.next() {
            if let Some(n2) = neighbours.next() {
                // only push to heap if the next neighbour is in the opposite quadrant
                if (data[n2].1 - data[neighbour].1) * (data[neighbour].1 - data[d.idx].1) <= 0.0 {
                    heap.push(mk_d(
                        data[d.idx].0 - data[neighbour].0 + d.dist,
                        d.idx,
                        d.use_left,
                    ));
                }
            }
            // since we cannot remove the now changed neighbour from the heap, we mark it as removed instead
            // and move the neighbour to our position
            if d.use_left {
                data[d.idx] = data[neighbour];
            } else {
                data[d.idx].0 = data[neighbour].0;
            }
            data[neighbour].1 = -1.0;
        }

        to_remove -= 1;
        if to_remove == 0 {
            break;
        }
    }
    data.retain(|x| x.1 >= 0.0);

    // skipping every other occurrence of the same bin may end up draining the heap, so check whether we need to run a second pass
    compact(data, mode, max_size);
}

impl PartialOrd for StepFunction {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        let mut ret = None;
        for (_x, (l, r)) in self.zip(other) {
            if l < r {
                if ret == Some(Ordering::Greater) {
                    return None;
                }
                ret = Some(Ordering::Less);
            } else if l > r {
                if ret == Some(Ordering::Less) {
                    return None;
                }
                ret = Some(Ordering::Greater);
            }
        }
        ret.or(Some(Ordering::Equal))
    }
}

/// Iterator over a pair of iterators, yielding the x value and the pair of y values for each
/// point where one of the iterators has a point.
///
/// This iterator will coalesce points with approximately the same x value.
pub(crate) struct PairIterators<I1, I2>
where
    I1: Iterator<Item = (f32, f32)>,
    I2: Iterator<Item = (f32, f32)>,
{
    left: AggregatingIterator<I1>,
    l_prev: f32,
    right: AggregatingIterator<I2>,
    r_prev: f32,
}

impl<I1, I2> PairIterators<I1, I2>
where
    I1: Iterator<Item = (f32, f32)>,
    I2: Iterator<Item = (f32, f32)>,
{
    pub fn new(left: I1, right: I2) -> Self {
        Self {
            left: AggregatingIterator::new(left),
            l_prev: 0.0,
            right: AggregatingIterator::new(right),
            r_prev: 0.0,
        }
    }
}

impl<I1, I2> Iterator for PairIterators<I1, I2>
where
    I1: Iterator<Item = (f32, f32)>,
    I2: Iterator<Item = (f32, f32)>,
{
    /// yields (x, (left_y, right_y))
    type Item = (f32, (f32, f32));

    fn next(&mut self) -> Option<Self::Item> {
        let left = self.left.peek();
        let right = self.right.peek();

        match (left, right) {
            (Some((lx, ly)), Some((rx, ry))) => {
                if (lx - rx).abs() / rx.max(1.0e-10) <= 5.0 * f32::EPSILON {
                    self.l_prev = self.left.next().unwrap().1;
                    self.r_prev = self.right.next().unwrap().1;
                    Some((lx, (ly, ry)))
                } else if lx < rx {
                    self.l_prev = self.left.next().unwrap().1;
                    Some((lx, (ly, self.r_prev)))
                } else {
                    self.r_prev = self.right.next().unwrap().1;
                    Some((rx, (self.l_prev, ry)))
                }
            }
            (Some((lx, ly)), None) => {
                self.l_prev = self.left.next().unwrap().1;
                Some((lx, (ly, self.r_prev)))
            }
            (None, Some((rx, ry))) => {
                self.r_prev = self.right.next().unwrap().1;
                Some((rx, (self.l_prev, ry)))
            }
            (None, None) => None,
        }
    }
}

/// An iterator that aggregates values for which the first component of the pair
/// is within 5*f32::EPSILON of each other.
pub struct AggregatingIterator<I: Iterator> {
    inner: Peekable<I>,
    current: Option<(f32, f32)>,
}

impl<I> AggregatingIterator<I>
where
    I: Iterator<Item = (f32, f32)>,
{
    pub fn new(iter: I) -> Self {
        AggregatingIterator {
            inner: iter.peekable(),
            current: None,
        }
    }

    fn peek(&mut self) -> Option<(f32, f32)> {
        if self.current.is_some() {
            // already computed
            return self.current;
        } else {
            // compute the next value
            self.current = self.inner.next();
        }

        let first = self.current?;
        let mut last = first;

        while let Some(&next) = self.inner.peek() {
            if (next.0 - first.0).abs() / first.0 <= 5.0 * f32::EPSILON {
                last = next;
                self.inner.next();
            } else {
                break;
            }
        }

        self.current = Some((first.0 + (last.0 - first.0) / 2.0, last.1));
        self.current
    }
}

impl<I> Iterator for AggregatingIterator<I>
where
    I: Iterator<Item = (f32, f32)>,
{
    type Item = (f32, f32);

    fn next(&mut self) -> Option<Self::Item> {
        self.peek();
        self.current.take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compact_even() {
        let data = vec![
            (0.0, 0.1),
            (0.1, 0.2),
            (0.2, 0.3),
            (0.3, 0.4),
            (0.4, 0.5),
            (0.5, 0.6),
            (0.6, 0.7),
            (0.7, 0.8),
            (0.8, 0.9),
            (0.9, 1.0),
        ];
        let mut data1 = data.clone();
        compact(&mut data1, CompactionMode::UnderApproximate, 5);
        assert_eq!(
            data1,
            vec![(0.0, 0.1), (0.1, 0.2), (0.3, 0.4), (0.5, 0.6), (0.9, 1.0)]
        );
        let mut data2 = data.clone();
        compact(&mut data2, CompactionMode::OverApproximate, 5);
        assert_eq!(
            data2,
            vec![(0.0, 0.3), (0.3, 0.5), (0.5, 0.7), (0.7, 0.9), (0.9, 1.0)]
        );
    }

    #[test]
    fn test_compact_begin() {
        let data = vec![
            (0.0, 0.1),
            (0.1, 0.2),
            (0.2, 0.3),
            (0.3, 0.4),
            (0.5, 0.5),
            (0.7, 0.6),
            (0.9, 0.7),
        ];
        let mut data1 = data.clone();
        compact(&mut data1, CompactionMode::UnderApproximate, 5);
        assert_eq!(
            data1,
            vec![(0.0, 0.1), (0.1, 0.2), (0.3, 0.4), (0.5, 0.5), (0.9, 0.7)]
        );
        let mut data2 = data.clone();
        compact(&mut data2, CompactionMode::OverApproximate, 5);
        assert_eq!(
            data2,
            vec![(0.0, 0.2), (0.2, 0.4), (0.5, 0.5), (0.7, 0.6), (0.9, 0.7)]
        );
    }

    #[test]
    fn test_compact_middle() {
        let data = vec![
            (0.0, 0.1),
            (0.2, 0.3),
            (0.4, 0.5),
            (0.5, 0.6),
            (0.7, 0.8),
            (0.9, 1.0),
        ];
        let mut data1 = data.clone();
        compact(&mut data1, CompactionMode::UnderApproximate, 5);
        assert_eq!(
            data1,
            vec![(0.0, 0.1), (0.2, 0.3), (0.5, 0.6), (0.7, 0.8), (0.9, 1.0)]
        );
        let mut data1 = data.clone();
        compact(&mut data1, CompactionMode::OverApproximate, 5);
        assert_eq!(
            data1,
            vec![(0.0, 0.1), (0.2, 0.3), (0.4, 0.6), (0.7, 0.8), (0.9, 1.0)]
        );
    }

    #[test]
    fn test_compact_edges() {
        let data = vec![
            (0.1, 0.2),
            (0.2, 0.3),
            (0.3, 0.4),
            (0.5, 0.6),
            (0.7, 0.8),
            (0.8, 0.9),
            (0.9, 1.0),
        ];
        let mut data1 = data.clone();
        compact(&mut data1, CompactionMode::UnderApproximate, 5);
        assert_eq!(
            data1,
            vec![(0.1, 0.2), (0.3, 0.4), (0.5, 0.6), (0.7, 0.8), (0.9, 1.0)]
        );
        let mut data1 = data.clone();
        compact(&mut data1, CompactionMode::OverApproximate, 5);
        assert_eq!(
            data1,
            vec![(0.1, 0.3), (0.3, 0.4), (0.5, 0.6), (0.7, 0.9), (0.9, 1.0)]
        );
    }
}
