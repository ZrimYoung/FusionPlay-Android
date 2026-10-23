//! Mac-only timed SPSC PCM transport and real-time output. The decoder is the
//! sole producer; one CoreAudio stream is the sole consumer. Slots are published
//! with release/acquire ordering and never overwritten until consumed.
//! No locks, allocation, file IO, JSON or foreign callbacks on the audio thread.
use super::*;
use std::sync::atomic::AtomicUsize;

const CAPACITY: usize = MIPLAY_SOURCE_SAMPLE_RATE * MIPLAY_MAX_BUFFER_MILLIS / 1000;
const NO_PTS: i64 = i64::MIN;
const FADE_SECONDS: f64 = 0.005;
const RESYNC_US: f64 = 100_000.0;

struct Slot {
    left: AtomicU32,
    right: AtomicU32,
    pts: AtomicI64,
}
#[derive(Clone, Copy, Debug)]
struct Frame {
    left: f32,
    right: f32,
    pts: Option<f64>,
}
pub(super) struct PcmRing {
    slots: Box<[Slot]>,
    head: AtomicUsize,
    tail: AtomicUsize,
    dropped: AtomicU64,
}
impl PcmRing {
    fn new(capacity: usize) -> Self {
        assert!(capacity >= 2);
        Self {
            slots: (0..capacity)
                .map(|_| Slot {
                    left: AtomicU32::new(0),
                    right: AtomicU32::new(0),
                    pts: AtomicI64::new(NO_PTS),
                })
                .collect(),
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
            dropped: AtomicU64::new(0),
        }
    }
    pub(super) fn push_timed(&self, samples: &[f32], pts: Option<f64>) {
        let frames = samples.len() / 2;
        let head = self.head.load(Ordering::Relaxed);
        let used = head.wrapping_sub(self.tail.load(Ordering::Acquire));
        if frames > self.slots.len().saturating_sub(used) {
            self.dropped.fetch_add(frames as u64, Ordering::Relaxed);
            return; // Bounded overflow: never overwrite data the callback is reading.
        }
        for (i, pair) in samples.chunks_exact(2).enumerate() {
            let slot = &self.slots[head.wrapping_add(i) % self.slots.len()];
            slot.left.store(pair[0].to_bits(), Ordering::Relaxed);
            slot.right.store(pair[1].to_bits(), Ordering::Relaxed);
            slot.pts.store(
                pts.map(|p| {
                    (p + i as f64 * 1_000_000.0 / MIPLAY_SOURCE_SAMPLE_RATE as f64).round() as i64
                })
                .unwrap_or(NO_PTS),
                Ordering::Relaxed,
            );
        }
        self.head
            .store(head.wrapping_add(frames), Ordering::Release);
    }
    pub(super) fn buffered_frames(&self) -> usize {
        // This is also sampled by telemetry: tail first prevents a stale head
        // paired with a newer tail from appearing as a wrapped huge queue.
        let tail = self.tail.load(Ordering::Acquire);
        self.head
            .load(Ordering::Acquire)
            .wrapping_sub(tail)
            .min(self.slots.len())
    }
    fn peek(&self, offset: usize) -> Option<Frame> {
        let tail = self.tail.load(Ordering::Relaxed);
        if offset >= self.head.load(Ordering::Acquire).wrapping_sub(tail) {
            return None;
        }
        let slot = &self.slots[tail.wrapping_add(offset) % self.slots.len()];
        let pts = slot.pts.load(Ordering::Relaxed);
        Some(Frame {
            left: f32::from_bits(slot.left.load(Ordering::Relaxed)),
            right: f32::from_bits(slot.right.load(Ordering::Relaxed)),
            pts: (pts != NO_PTS).then_some(pts as f64),
        })
    }
    fn consume(&self, frames: usize) -> usize {
        let tail = self.tail.load(Ordering::Relaxed);
        let n = frames.min(self.head.load(Ordering::Acquire).wrapping_sub(tail));
        self.tail.store(tail.wrapping_add(n), Ordering::Release);
        n
    }
}

#[derive(Default)]
struct Health {
    underruns: AtomicU64,
    resyncs: AtomicU64,
    output_frames: AtomicU64,
    silence_frames: AtomicU64,
    latency_us: AtomicU64,
    error_us: AtomicI64,
    callback_frames: AtomicUsize,
    failed: AtomicBool,
    stop: AtomicBool,
}
pub(super) struct MacAudioStream {
    stream: Option<cpal::Stream>,
    health: Arc<Health>,
    reporter: Option<thread::JoinHandle<()>>,
}
impl Drop for MacAudioStream {
    fn drop(&mut self) {
        self.stream.take();
        self.health.stop.store(true, Ordering::Release);
        if let Some(reporter) = self.reporter.take() {
            let _ = reporter.join();
        }
    }
}

// Unlike the SDK's general clock accessor, this snapshot is bounded even if a
// clock writer is preempted. The callback retains its current rate on contention.
fn clock_now(clock: &MiPlayPresentationClock) -> Option<i64> {
    if !clock.synchronization_ready() {
        return None;
    }
    for _ in 0..3 {
        let revision = clock.clock_model_revision.load(Ordering::Acquire);
        if revision & 1 != 0 {
            continue;
        }
        let base = clock.clock_base_local_micros.load(Ordering::Relaxed);
        let offset = clock.clock_offset_at_base_micros.load(Ordering::Relaxed);
        let rate = clock.clock_rate_ppb.load(Ordering::Relaxed);
        if revision == clock.clock_model_revision.load(Ordering::Acquire) {
            let now = clock.local_now_micros();
            let adjust = (i128::from(now.saturating_sub(base)) * i128::from(rate) / 1_000_000_000)
                .clamp(i64::MIN as i128, i64::MAX as i128) as i64;
            return Some(now.saturating_add(offset).saturating_add(adjust));
        }
    }
    None
}

struct Renderer {
    phase: f64,
    running: bool,
    gain: f32,
    last: (f32, f32),
    rebuffer: bool,
    rate: f64,
    expected_pts: Option<f64>,
}
impl Renderer {
    fn new(rate: f64) -> Self {
        Self {
            phase: 0.0,
            running: false,
            gain: 0.0,
            last: (0.0, 0.0),
            rebuffer: false,
            rate,
            expected_pts: None,
        }
    }
    fn silence(&mut self, step: f32) -> (f32, f32) {
        // Decay the actual last output, including volume, rather than jumping to zero.
        let old = self.gain;
        self.gain = (self.gain - step).max(0.0);
        let scale = if old > 0.0 { self.gain / old } else { 0.0 };
        self.last.0 *= scale;
        self.last.1 *= scale;
        self.last
    }
    fn next(
        &mut self,
        queue: &PcmRing,
        rate: f64,
        volume: f32,
        step: f32,
        health: &Health,
    ) -> (f32, f32) {
        let (Some(a), Some(b)) = (queue.peek(0), queue.peek(1)) else {
            if self.running {
                health.underruns.fetch_add(1, Ordering::Relaxed);
            }
            self.running = false;
            self.phase = 0.0;
            self.expected_pts = None;
            return self.silence(step);
        };
        if let (Some(expected), Some(pts)) = (self.expected_pts, a.pts) {
            if (expected - pts).abs() > RESYNC_US {
                self.rebuffer = true;
            }
        }
        // Never interpolate across a discontinuous timestamp boundary.
        if let (Some(a_pts), Some(b_pts)) = (a.pts, b.pts) {
            if (b_pts - a_pts - 1_000_000.0 / MIPLAY_SOURCE_SAMPLE_RATE as f64).abs() > RESYNC_US {
                self.rebuffer = true;
                if self.gain == 0.0 {
                    queue.consume(1);
                }
            }
        }
        if self.rebuffer {
            let value = self.silence(step);
            if self.gain == 0.0 {
                self.running = false;
                self.phase = 0.0;
                self.expected_pts = None;
                self.rebuffer = false;
                health.resyncs.fetch_add(1, Ordering::Relaxed);
            }
            return value;
        }
        self.gain = (self.gain + step).min(1.0);
        let phase = self.phase as f32;
        self.last = (
            (a.left + (b.left - a.left) * phase) * volume * self.gain,
            (a.right + (b.right - a.right) * phase) * volume * self.gain,
        );
        self.phase += rate;
        let consumed = queue
            .consume((self.phase.floor() as usize).min(queue.buffered_frames().saturating_sub(1)));
        self.phase -= consumed as f64;
        self.expected_pts = a
            .pts
            .map(|p| p + consumed as f64 * 1_000_000.0 / MIPLAY_SOURCE_SAMPLE_RATE as f64);
        health.output_frames.fetch_add(1, Ordering::Relaxed);
        self.last
    }
}

fn build<T: SizedSample + FromSample<f32>>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    queue: Arc<PcmRing>,
    paused: Arc<AtomicBool>,
    volume: Arc<AtomicU32>,
    clock: Arc<MiPlayPresentationClock>,
    telemetry: Arc<MiPlayLatencyTelemetry>,
    health: Arc<Health>,
) -> Result<cpal::Stream> {
    let sample_rate = config.sample_rate;
    let channels = config.channels as usize;
    let nominal = MIPLAY_SOURCE_SAMPLE_RATE as f64 / sample_rate as f64;
    let step = (1.0 / (FADE_SECONDS * sample_rate as f64)) as f32;
    let mut renderer = Renderer::new(nominal);
    let failure_health = health.clone();
    let mut latency = 0.0;
    Ok(device.build_output_stream(
        config,
        move |output: &mut [T], info| {
            let frames = output.len() / channels;
            health.callback_frames.store(frames, Ordering::Relaxed);
            let measured = output_latency_millis(info, sample_rate, frames);
            latency = if latency == 0.0 {
                measured
            } else {
                latency * 0.98 + measured * 0.02
            };
            health
                .latency_us
                .store((latency * 1000.0) as u64, Ordering::Relaxed);
            telemetry.update_output_latency(latency);
            let is_paused = paused.load(Ordering::Acquire);
            let buffered = queue.buffered_frames();
            let mut leading = 0;
            if is_paused {
                queue.consume(buffered);
                renderer.running = false;
                renderer.phase = 0.0;
                renderer.expected_pts = None;
            } else {
                let schedule = queue
                    .peek(0)
                    .and_then(|f| f.pts)
                    .zip(clock_now(&clock))
                    .and_then(|(pts, now)| {
                        usable_presentation_schedule_error_micros(
                            pts + renderer.phase * 1_000_000.0 / MIPLAY_SOURCE_SAMPLE_RATE as f64,
                            clock.presentation_offset_micros.load(Ordering::Acquire),
                            now,
                            latency,
                        )
                    });
                if let Some(mut error) = schedule {
                    health.error_us.store(error as i64, Ordering::Relaxed);
                    if renderer.running {
                        if error.abs() > RESYNC_US {
                            renderer.rebuffer = true;
                        }
                        let correction = if error.abs() <= 2000.0 {
                            0.0
                        } else {
                            (-error / (MIPLAY_DRIFT_CORRECTION_SECONDS * 1_000_000.0))
                                .clamp(-MIPLAY_MAX_RATE_CORRECTION, MIPLAY_MAX_RATE_CORRECTION)
                        };
                        renderer.rate += (nominal * (1.0 + correction) - renderer.rate) * 0.02;
                    } else if renderer.gain == 0.0 {
                        if error < -2000.0 {
                            let drop = queue.consume(
                                ((-error) * MIPLAY_SOURCE_SAMPLE_RATE as f64 / 1_000_000.0)
                                    as usize,
                            );
                            queue.dropped.fetch_add(drop as u64, Ordering::Relaxed);
                            error += drop as f64 * 1_000_000.0 / MIPLAY_SOURCE_SAMPLE_RATE as f64;
                        }
                        leading = ((error.max(0.0) * sample_rate as f64 / 1_000_000.0).ceil()
                            as usize)
                            .min(frames);
                        renderer.running = leading < frames && queue.buffered_frames() >= 2;
                        renderer.rate = nominal;
                    }
                } else if !renderer.running && renderer.gain == 0.0 {
                    renderer.running = buffered >= synchronized_buffer_frames(latency);
                    renderer.rate = nominal;
                }
            }
            let gain = volume.load(Ordering::Relaxed).min(100) as f32 / 100.0;
            for (index, frame) in output.chunks_mut(channels).enumerate() {
                let pair = if is_paused || !renderer.running || index < leading {
                    health.silence_frames.fetch_add(1, Ordering::Relaxed);
                    renderer.silence(step)
                } else {
                    renderer.next(&queue, renderer.rate, gain, step, &health)
                };
                for (channel, sample) in frame.iter_mut().enumerate() {
                    let value = match channel {
                        0 if channels == 1 => (pair.0 + pair.1) * 0.5,
                        0 => pair.0,
                        1 => pair.1,
                        _ => 0.0,
                    };
                    *sample = T::from_sample(value);
                }
            }
            telemetry.update_buffered_frames(queue.buffered_frames());
        },
        move |_| {
            failure_health.failed.store(true, Ordering::Release);
        },
        None,
    )?)
}

pub(super) fn open_native_audio_output(
    requested: Option<&str>,
    paused: Arc<AtomicBool>,
    volume: Arc<AtomicU32>,
    clock: Arc<MiPlayPresentationClock>,
    telemetry: Arc<MiPlayLatencyTelemetry>,
    events: EventEmitter,
) -> Result<(Arc<PcmRing>, MacAudioStream)> {
    let host = cpal::default_host();
    let device = match requested {
        Some(id) => host
            .output_devices()?
            .find(|d| {
                d.id().map(|i| i.to_string() == id).unwrap_or(false)
                    || d.description().map(|n| n.name() == id).unwrap_or(false)
            })
            .context("Selected audio device disconnected")?,
        None => host
            .default_output_device()
            .context("No system audio output")?,
    };
    let default = device.default_output_config()?;
    let supported = device
        .supported_output_configs()?
        .filter(|r| {
            r.min_sample_rate() <= 48000
                && r.max_sample_rate() >= 48000
                && matches!(
                    r.sample_format(),
                    cpal::SampleFormat::F32 | cpal::SampleFormat::I16 | cpal::SampleFormat::U16
                )
        })
        .min_by_key(|r| {
            (
                r.channels().abs_diff(2),
                r.sample_format() != cpal::SampleFormat::F32,
            )
        })
        .map(|r| r.with_sample_rate(48000))
        .unwrap_or(default);
    let config = supported.config();
    let queue = Arc::new(PcmRing::new(CAPACITY));
    let health = Arc::new(Health::default());
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => build::<f32>(
            &device,
            &config,
            queue.clone(),
            paused,
            volume,
            clock,
            telemetry,
            health.clone(),
        )?,
        cpal::SampleFormat::I16 => build::<i16>(
            &device,
            &config,
            queue.clone(),
            paused,
            volume,
            clock,
            telemetry,
            health.clone(),
        )?,
        cpal::SampleFormat::U16 => build::<u16>(
            &device,
            &config,
            queue.clone(),
            paused,
            volume,
            clock,
            telemetry,
            health.clone(),
        )?,
        format => bail!("Unsupported audio format: {format}"),
    };
    events(
        json!({"event":"audio_output_ready", "device_name":device.description()?.name(), "sample_rate":config.sample_rate, "channels":config.channels}),
    );
    let report_health = health.clone();
    let report_queue = queue.clone();
    let reporter = thread::Builder::new().name("miplay-audio-health".into()).spawn(move || {
        let mut last = 0; let mut ticks = 0;
        while !report_health.stop.load(Ordering::Acquire) {
            thread::sleep(StdDuration::from_millis(100)); ticks += 1;
            if ticks < 10 { continue; } ticks = 0;
            let rendered = report_health.output_frames.load(Ordering::Relaxed);
            events(json!({"event":"audio_health", "queue_ms":report_queue.buffered_frames() as f64 / 48.0,
                "output_latency_ms": report_health.latency_us.load(Ordering::Relaxed) as f64 / 1000.0,
                "schedule_error_ms": report_health.error_us.load(Ordering::Relaxed) as f64 / 1000.0,
                "underruns":report_health.underruns.load(Ordering::Relaxed), "dropped_frames":report_queue.dropped.load(Ordering::Relaxed),
                "resyncs":report_health.resyncs.load(Ordering::Relaxed), "callback_frames":report_health.callback_frames.load(Ordering::Relaxed),
                "silence_frames":report_health.silence_frames.load(Ordering::Relaxed), "lock_contentions":0, "rendering": rendered > last}));
            last = rendered;
            if report_health.failed.swap(false, Ordering::AcqRel) {
                events(json!({"event":"error", "code":"miplay_audio_output_failed", "message":"音频设备发生变化，请重新启动接收并在手机上重新选择设备"}));
            }
        }
    })?;
    let managed = MacAudioStream {
        stream: Some(stream),
        health,
        reporter: Some(reporter),
    };
    managed.stream.as_ref().unwrap().play()?;
    Ok((queue, managed))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ring_is_bounded_and_preserves_timestamps() {
        let q = PcmRing::new(4);
        q.push_timed(&[1., 2., 3., 4., 5., 6.], Some(1000.));
        q.push_timed(&[7., 8., 9., 10.], Some(1062.5));
        assert_eq!(q.buffered_frames(), 3);
        assert_eq!(q.dropped.load(Ordering::Relaxed), 2);
        assert_eq!(q.peek(1).unwrap().pts, Some(1021.));
        q.consume(2);
        q.push_timed(&[7., 8., 9., 10.], Some(1062.5));
        assert_eq!(q.peek(0).unwrap().left, 5.);
        assert_eq!(q.peek(2).unwrap().right, 10.);
    }
    #[test]
    fn underrun_fades_instead_of_clicking() {
        let q = PcmRing::new(1024);
        q.push_timed(&vec![0.8; 1000], Some(0.));
        let h = Health::default();
        let mut r = Renderer::new(1.);
        r.running = true;
        let step = 1.0 / 240.0;
        let mut previous = 0.0_f32;
        let mut max_delta = 0.0_f32;
        for _ in 0..1000 {
            let v = if r.running {
                r.next(&q, 1., 1., step, &h).0
            } else {
                r.silence(step).0
            };
            max_delta = max_delta.max((v - previous).abs());
            previous = v;
        }
        assert!(max_delta < 0.004);
        assert_eq!(previous, 0.0);
        assert_eq!(h.underruns.load(Ordering::Relaxed), 1);
    }
    #[test]
    fn resampling_retains_phase_and_duration() {
        let q = PcmRing::new(50000);
        q.push_timed(&vec![0.2; 96000], Some(0.));
        let h = Health::default();
        let mut r = Renderer::new(48000. / 44100.);
        r.running = true;
        for _ in 0..22050 {
            r.next(&q, 48000. / 44100., 1., 1. / 240., &h);
        }
        assert!((q.buffered_frames() as i64 - 24000).abs() <= 1);
        assert_eq!(h.underruns.load(Ordering::Relaxed), 0);
    }
    #[test]
    fn timestamp_jump_is_not_interpolated() {
        let q = PcmRing::new(1000);
        q.push_timed(&vec![0.5; 600], Some(0.));
        q.push_timed(&vec![-0.5; 600], Some(1_000_000.));
        let h = Health::default();
        let mut r = Renderer::new(1.);
        r.running = true;
        let mut previous = 0.0_f32;
        for _ in 0..600 {
            let v = if r.running {
                r.next(&q, 1., 1., 1. / 240., &h).0
            } else {
                r.silence(1. / 240.).0
            };
            assert!((v - previous).abs() < 0.003);
            previous = v;
        }
        assert!(!r.running);
        assert_eq!(h.resyncs.load(Ordering::Relaxed), 1);
    }
    #[test]
    fn spsc_publication_never_exposes_torn_frames() {
        let q = Arc::new(PcmRing::new(64));
        let p = q.clone();
        let writer = thread::spawn(move || {
            for i in 0..10000 {
                while p.buffered_frames() >= 63 {
                    thread::yield_now();
                }
                p.push_timed(&[i as f32, -(i as f32)], Some(i as f64 * 100.));
            }
        });
        for i in 0..10000 {
            let f = loop {
                if let Some(f) = q.peek(0) {
                    break f;
                }
                thread::yield_now();
            };
            assert_eq!(f.left, i as f32);
            assert_eq!(f.right, -(i as f32));
            assert_eq!(f.pts, Some(i as f64 * 100.));
            q.consume(1);
        }
        writer.join().unwrap();
    }
}
