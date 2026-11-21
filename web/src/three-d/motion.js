// Critically damped springs: interruptible by construction (retargeting keeps velocity),
// never overshoot, and land exactly so idle frames stay idle.

export class Spring {
  constructor(value = 0, omega = 7.5) {
    this.x = value;
    this.v = 0;
    this.target = value;
    this.omega = omega; // ~95% settled at 4.7/omega seconds
  }

  set(target) {
    this.target = target;
    return this;
  }

  snap(value) {
    this.x = this.target = value;
    this.v = 0;
    return this;
  }

  get moving() {
    return this.x !== this.target || this.v !== 0;
  }

  step(dt) {
    if (!this.moving) return false;
    const w = this.omega;
    const x0 = this.x - this.target;
    const v0 = this.v;
    const e = Math.exp(-w * dt);
    const x = (x0 + (v0 + w * x0) * dt) * e;
    const v = (v0 - (v0 + w * x0) * w * dt) * e;
    if (Math.abs(x) < 1e-5 && Math.abs(v) < 1e-4) {
      this.x = this.target;
      this.v = 0;
    } else {
      this.x = this.target + x;
      this.v = v;
    }
    return true;
  }
}

/** Three springs sharing one omega, for points. */
export class SpringV3 {
  constructor(omega = 7.5) {
    this.s = [new Spring(0, omega), new Spring(0, omega), new Spring(0, omega)];
  }

  set(v) {
    this.s[0].set(v.x);
    this.s[1].set(v.y);
    this.s[2].set(v.z);
    return this;
  }

  snap(v) {
    this.s[0].snap(v.x);
    this.s[1].snap(v.y);
    this.s[2].snap(v.z);
    return this;
  }

  step(dt) {
    let m = false;
    for (const s of this.s) m = s.step(dt) || m;
    return m;
  }

  read(out) {
    return out.set(this.s[0].x, this.s[1].x, this.s[2].x);
  }
}

// Exponential smoothing that lands exactly on the target.
export function approach(cur, target, rate, dt) {
  const v = target + (cur - target) * Math.exp(-rate * dt);
  return Math.abs(v - target) < 1e-5 ? target : v;
}

/** CSS cubic-bezier(x1, y1, x2, y2) as a function of t in [0, 1]. */
export function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const X = (t) => ((ax * t + bx) * t + cx) * t;
  const dX = (t) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 6; i++) {
      const d = dX(t);
      if (Math.abs(d) < 1e-6) break;
      t -= (X(t) - x) / d;
    }
    t = Math.min(1, Math.max(0, t));
    return ((ay * t + by) * t + cy) * t;
  };
}
