/** Counters and gauges exposed at /metrics in Prometheus text format. */
export class Metrics {
  readonly counters = new Map<string, number>();
  readonly gauges = new Map<string, () => number>();

  inc(name: string, labels?: Record<string, string>, by = 1): void {
    const key = labels ? `${name}{${Object.entries(labels).map(([k, v]) => `${k}="${v}"`).join(",")}}` : name;
    this.counters.set(key, (this.counters.get(key) ?? 0) + by);
  }
  get(name: string, labels?: Record<string, string>): number {
    const key = labels ? `${name}{${Object.entries(labels).map(([k, v]) => `${k}="${v}"`).join(",")}}` : name;
    return this.counters.get(key) ?? 0;
  }
  gauge(name: string, fn: () => number): void {
    this.gauges.set(name, fn);
  }
  render(): string {
    const lines: string[] = [];
    for (const [k, fn] of this.gauges) lines.push(`${k} ${fn()}`);
    for (const [k, v] of this.counters) lines.push(`${k} ${v}`);
    return lines.join("\n") + "\n";
  }
}
