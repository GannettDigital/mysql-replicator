//! Optional per-feed measurements. No globals, locks, per-cell timers or output.
use super::Checked;
use std::{cell::Cell, time::Instant};

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Timing {
    pub count: u64,
    pub failures: u64,
    pub nanoseconds: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct ProfileOutput {
    pub stages: [Timing; 7],
}
pub struct Profile {
    enabled: bool,
    output: Cell<ProfileOutput>,
}
impl Profile {
    pub fn new(enabled: bool) -> Self {
        Self {
            enabled,
            output: Cell::new(ProfileOutput::default()),
        }
    }
    pub fn snapshot(&self) -> ProfileOutput {
        self.output.get()
    }
    pub fn measure<T>(&self, stage: usize, body: impl FnOnce() -> Checked<T>) -> Checked<T> {
        if !self.enabled {
            return body();
        }
        let mut timer = Timer {
            profile: self,
            stage,
            start: Instant::now(),
            failed: true,
        };
        let result = body();
        timer.failed = result.is_err();
        result
    }
}
struct Timer<'a> {
    profile: &'a Profile,
    stage: usize,
    start: Instant,
    failed: bool,
}
impl Drop for Timer<'_> {
    fn drop(&mut self) {
        let mut output = self.profile.output.get();
        let sample = &mut output.stages[self.stage];
        sample.count += 1;
        sample.failures += u64::from(self.failed);
        sample.nanoseconds += self.start.elapsed().as_nanos().min(u64::MAX as u128) as u64;
        self.profile.output.set(output);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disabled_error_and_panic_accounting() {
        let disabled = Profile::new(false);
        assert!(disabled.measure(0, || Err::<(), _>((2, "bad"))).is_err());
        assert_eq!(disabled.snapshot().stages[0].count, 0);
        let enabled = Profile::new(true);
        enabled.measure(0, || Ok(())).unwrap();
        assert!(enabled.measure(1, || Err::<(), _>((2, "bad"))).is_err());
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _ = enabled.measure(2, || -> Checked<()> { panic!("injected") });
        }));
        let s = enabled.snapshot().stages;
        assert_eq!((s[0].count, s[0].failures), (1, 0));
        assert_eq!((s[1].count, s[1].failures), (1, 1));
        assert_eq!((s[2].count, s[2].failures), (1, 1));
    }
}
