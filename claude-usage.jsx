export const command = "cat ~/.config/claude-usage/widget-data.json";

export const refreshFrequency = 5 * 60 * 1000;

const PALETTE = [
  "#6EE7B7", "#67E8F9", "#A78BFA", "#FCA5A1",
  "#FDBA74", "#86EFAC", "#7DD3FC", "#C4B5FD",
];

function fmtTokens(n) {
  if (n >= 1000000) return (n / 1000000).toFixed(1) + "M";
  if (n >= 1000) return Math.round(n / 1000) + "K";
  return String(n);
}

function getColor(project, idx, colors) {
  return colors[project] || PALETTE[idx % PALETTE.length];
}

function fmtRemaining(endIso) {
  if (!endIso) return null;
  const mins = Math.floor((new Date(endIso) - new Date()) / 60000);
  if (mins <= 0) return null;
  const d = Math.floor(mins / 1440);
  const h = Math.floor((mins % 1440) / 60);
  const m = mins % 60;
  if (d > 0) return d + "d " + h + "h";
  if (h > 0) return h + "h " + m + "m";
  return m + "m";
}

function barColor(pct) {
  if (pct >= 80) return "#FCA5A1";
  if (pct >= 50) return "#FDBA74";
  return "#6EE7B7";
}

function usageBar(label, pct) {
  const clamped = Math.min(100, Math.max(0, pct));
  const c = barColor(pct);
  return (
    <div style={{ display: "flex", alignItems: "center", marginBottom: 6 }}>
      <span style={{ width: 44, fontSize: 10, color: "#888", fontWeight: 600 }}>{label}</span>
      <span style={{ width: 38, fontSize: 11, color: c, fontVariantNumeric: "tabular-nums", textAlign: "right", marginRight: 8 }}>
        {Math.round(pct)}%
      </span>
      <div style={{ flex: 1, height: 8, background: "rgba(255,255,255,0.08)", borderRadius: 4, overflow: "hidden" }}>
        <div style={{ width: clamped + "%", height: "100%", background: c, borderRadius: 4, transition: "width 0.3s ease" }} />
      </div>
    </div>
  );
}

export const className = `
  bottom: 2px;
  left: 20px;
  width: 320px;
  max-height: 500px;
  overflow-y: hidden;
  background: rgba(20, 20, 35, 0.92);
  -webkit-backdrop-filter: blur(20px);
  border-radius: 14px;
  padding: 15px;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  color: #fff;
  box-shadow: 0 8px 32px rgba(0,0,0,0.4);
`;

export const render = ({ output }) => {
  if (!output) return <div style={{ color: "#666", fontSize: 12 }}>Loading...</div>;

  let data;
  try {
    data = JSON.parse(output);
  } catch (e) {
    return <div style={{ color: "#f66", fontSize: 12 }}>Parse error</div>;
  }

  if (data.error) return <div style={{ color: "#f66", fontSize: 12 }}>Error: {data.error}</div>;

  const { weeklyWindow, currentWindow5h, daily, sortedProjects, projectTotals, colors, weekUtilization, weekEnd } = data;
  const totalOut = weeklyWindow?.totalOutput || 0;
  const activeSessions = weeklyWindow?.activeSessions || 0;
  const total5h = currentWindow5h?.totalOutput || 0;
  const pct5h = currentWindow5h?.utilization || 0;
  const pctWeek = weekUtilization || 0;
  const today = new Date().toISOString().slice(0, 10);

  const barMaxHeight = 60;
  const maxDayOut = Math.max(...(daily || []).map(d =>
    Object.values(d.projects || {}).reduce((a, b) => a + b, 0)
  ), 1);

  return (
    <div>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", marginBottom: 12 }}>
        <span style={{ color: activeSessions > 0 ? "#6EE7B7" : "#666", fontSize: 10, marginRight: 6 }}>
          {activeSessions > 0 ? "●" : "○"}
        </span>
        <span style={{ color: "#888", fontSize: 11, fontWeight: 600, letterSpacing: 1 }}>
          CLAUDE
        </span>
        <span style={{ flex: 1 }} />
        {total5h > 0 && (
          <span style={{ fontSize: 13, color: "#888", fontVariantNumeric: "tabular-nums", marginRight: 8 }}>
            5h {fmtTokens(total5h)}
          </span>
        )}
        <span style={{ fontSize: 16, fontWeight: 700, fontVariantNumeric: "tabular-nums" }}>
          {fmtTokens(totalOut)}
        </span>
      </div>

      {/* Limit gauges */}
      <div style={{ marginBottom: 14 }}>
        {usageBar(fmtRemaining(currentWindow5h?.windowEnd) || "5h", pct5h)}
        {usageBar(fmtRemaining(weekEnd) || "Week", pctWeek)}
      </div>

      {/* Bar chart */}
      <div style={{ display: "flex", gap: 4, marginBottom: 12 }}>
        {(daily || []).map((day, i) => {
          const dayOut = Object.values(day.projects || {}).reduce((a, b) => a + b, 0);
          const barHeight = maxDayOut > 0 ? Math.max(2, Math.round((dayOut / maxDayOut) * barMaxHeight)) : 2;
          const isToday = day.date === today;

          return (
            <div key={i} style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center" }}>
              <div style={{ height: barMaxHeight, display: "flex", flexDirection: "column", justifyContent: "flex-end", width: "100%" }}>
                {dayOut > 0 ? (
                  (sortedProjects || []).map((p, pi) => {
                    const pOut = (day.projects || {})[p] || 0;
                    if (pOut <= 0) return null;
                    const segH = Math.max(2, Math.round((pOut / dayOut) * barHeight));
                    return (
                      <div key={p} style={{
                        height: segH,
                        background: getColor(p, pi, colors || {}),
                        borderRadius: 2,
                        marginTop: 1,
                        width: "100%",
                      }} />
                    );
                  })
                ) : (
                  <div style={{ height: 2, background: "#333", borderRadius: 2, width: "100%" }} />
                )}
              </div>
              <div style={{
                fontSize: 9,
                color: isToday ? "#fff" : "#666",
                marginTop: 4,
                fontWeight: isToday ? 600 : 400,
              }}>
                {day.day}
              </div>
            </div>
          );
        })}
      </div>

      {/* Project legend */}
      {(sortedProjects || []).map((p, pi) => {
        const pct = totalOut > 0 ? Math.round((projectTotals[p] || 0) / totalOut * 100) : 0;
        const total = projectTotals[p] || 0;
        return (
          <div key={p} style={{ display: "flex", alignItems: "center", marginBottom: 3 }}>
            <span style={{ color: getColor(p, pi, colors || {}), fontSize: 8, marginRight: 6 }}>●</span>
            <span style={{ fontSize: 11, color: "#ccc", flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {p}
            </span>
            <span style={{ fontSize: 10, color: "#888", fontVariantNumeric: "tabular-nums", marginRight: 8 }}>
              {pct}%
            </span>
            <span style={{ fontSize: 10, fontWeight: 600, fontVariantNumeric: "tabular-nums" }}>
              {fmtTokens(total)}
            </span>
          </div>
        );
      })}
    </div>
  );
};
