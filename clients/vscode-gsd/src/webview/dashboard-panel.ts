import * as vscode from 'vscode';
import { GsdDataService } from '../parsers/gsd-data-service';
import { GsdSnapshot, HandoffEntry, Requirement } from '../types';

/**
 * Full-featured dashboard webview panel with:
 * - Health gauge with trend sparkline
 * - Requirements burndown chart
 * - Agent activity timeline
 * - Token cost bar chart
 * - Phase progress indicator
 * - Live engine status
 */
export class DashboardPanel {
  public static readonly viewType = 'gsd.dashboard';
  private static instance: DashboardPanel | undefined;
  private readonly panel: vscode.WebviewPanel;
  private disposables: vscode.Disposable[] = [];

  static createOrShow(extensionUri: vscode.Uri, dataService: GsdDataService): DashboardPanel {
    if (DashboardPanel.instance) {
      DashboardPanel.instance.panel.reveal(vscode.ViewColumn.One);
      return DashboardPanel.instance;
    }

    const panel = vscode.window.createWebviewPanel(
      DashboardPanel.viewType,
      'GSD Dashboard',
      vscode.ViewColumn.One,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [vscode.Uri.joinPath(extensionUri, 'media')],
      }
    );

    const instance = new DashboardPanel(panel, dataService);
    DashboardPanel.instance = instance;
    return instance;
  }

  private constructor(panel: vscode.WebviewPanel, private dataService: GsdDataService) {
    this.panel = panel;
    this.panel.webview.html = this.getHtml(dataService.getSnapshot());

    // Update on data change
    this.disposables.push(
      dataService.onDidChange(snap => {
        this.panel.webview.postMessage({ type: 'update', data: snap });
      })
    );

    // Handle messages from webview
    this.disposables.push(
      this.panel.webview.onDidReceiveMessage(msg => {
        if (msg.type === 'openFile') {
          const uri = vscode.Uri.file(msg.path);
          vscode.window.showTextDocument(uri);
        } else if (msg.type === 'refresh') {
          dataService.refresh();
        }
      })
    );

    this.panel.onDidDispose(() => {
      DashboardPanel.instance = undefined;
      this.disposables.forEach(d => d.dispose());
    });
  }

  private getHtml(snapshot: GsdSnapshot): string {
    const nonce = getNonce();
    return /*html*/ `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>GSD Dashboard</title>
<style nonce="${nonce}">
  :root {
    --bg: var(--vscode-editor-background);
    --fg: var(--vscode-editor-foreground);
    --border: var(--vscode-panel-border);
    --accent: var(--vscode-focusBorder);
    --green: #4ec9b0;
    --yellow: #dcdcaa;
    --red: #f44747;
    --blue: #569cd6;
    --orange: #ce9178;
    --purple: #c586c0;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: var(--vscode-font-family); color: var(--fg); background: var(--bg); padding: 16px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .grid-full { grid-column: 1 / -1; }
  .card {
    background: var(--vscode-editorWidget-background);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 16px;
  }
  .card h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.5px; opacity: 0.7; margin-bottom: 12px; }
  .health-gauge {
    display: flex; align-items: center; gap: 24px;
  }
  .gauge { position: relative; width: 140px; height: 140px; }
  .gauge svg { transform: rotate(-90deg); }
  .gauge-text {
    position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
    font-size: 28px; font-weight: bold;
  }
  .health-stats { flex: 1; }
  .health-stats .stat { display: flex; justify-content: space-between; padding: 4px 0; border-bottom: 1px solid var(--border); }
  .stat .label { opacity: 0.7; }
  .progress-bar { height: 8px; border-radius: 4px; background: var(--vscode-progressBar-background); overflow: hidden; margin-top: 8px; }
  .progress-fill { height: 100%; border-radius: 4px; transition: width 0.5s ease; }
  .phase-track { display: flex; gap: 4px; margin-top: 8px; }
  .phase-step {
    flex: 1; text-align: center; padding: 8px 4px; border-radius: 4px; font-size: 11px;
    background: var(--vscode-badge-background); opacity: 0.4;
  }
  .phase-step.active { opacity: 1; background: var(--accent); color: var(--vscode-badge-foreground); font-weight: bold; }
  .phase-step.done { opacity: 0.8; background: var(--green); color: #000; }
  .chart-container { width: 100%; height: 200px; position: relative; }
  .bar-chart { display: flex; align-items: flex-end; gap: 6px; height: 160px; padding-top: 8px; }
  .bar-group { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 4px; }
  .bar { width: 100%; min-width: 20px; border-radius: 3px 3px 0 0; transition: height 0.3s ease; position: relative; }
  .bar:hover::after {
    content: attr(data-tooltip); position: absolute; bottom: 100%; left: 50%; transform: translateX(-50%);
    background: var(--vscode-editorHoverWidget-background); border: 1px solid var(--border);
    padding: 4px 8px; border-radius: 3px; font-size: 11px; white-space: nowrap; z-index: 10;
  }
  .bar-label { font-size: 10px; opacity: 0.6; text-align: center; }
  .timeline { max-height: 200px; overflow-y: auto; }
  .timeline-entry {
    display: flex; align-items: center; gap: 8px; padding: 4px 0; border-bottom: 1px solid var(--border);
    font-size: 12px;
  }
  .timeline-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
  .timeline-dot.success { background: var(--green); }
  .timeline-dot.partial { background: var(--yellow); }
  .timeline-dot.failed { background: var(--red); }
  .timeline-agent { font-weight: bold; min-width: 60px; }
  .timeline-phase { opacity: 0.7; min-width: 80px; }
  .timeline-delta { min-width: 50px; text-align: right; }
  .engine-banner {
    display: flex; align-items: center; gap: 12px; padding: 12px; border-radius: 6px;
    background: var(--vscode-editorWidget-background); border: 1px solid var(--border); margin-bottom: 16px;
  }
  .engine-state { font-size: 16px; font-weight: bold; text-transform: uppercase; }
  .engine-state.running { color: var(--green); }
  .engine-state.sleeping { color: var(--yellow); }
  .engine-state.stalled { color: var(--red); }
  .engine-state.converged { color: var(--blue); }
  .engine-detail { font-size: 12px; opacity: 0.7; }
  .sparkline { display: flex; align-items: flex-end; gap: 1px; height: 40px; }
  .spark-bar { width: 3px; border-radius: 1px; background: var(--accent); }
  .req-burndown { display: flex; flex-direction: column; gap: 4px; }
  .req-row { display: flex; align-items: center; gap: 8px; }
  .req-row .label { width: 80px; font-size: 12px; }
  .req-bar-track { flex: 1; height: 16px; background: var(--vscode-progressBar-background); border-radius: 3px; overflow: hidden; display: flex; }
  .req-bar-seg { height: 100%; transition: width 0.5s ease; }
  .req-count { width: 40px; text-align: right; font-size: 12px; font-weight: bold; }
  .legend { display: flex; gap: 16px; margin-top: 8px; font-size: 11px; }
  .legend-item { display: flex; align-items: center; gap: 4px; }
  .legend-dot { width: 10px; height: 10px; border-radius: 2px; }
  button.gsd-btn {
    background: var(--vscode-button-background); color: var(--vscode-button-foreground);
    border: none; padding: 6px 12px; border-radius: 3px; cursor: pointer; font-size: 12px;
  }
  button.gsd-btn:hover { background: var(--vscode-button-hoverBackground); }
  .top-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
  .top-bar h1 { font-size: 18px; }
</style>
</head>
<body>
<div class="top-bar">
  <h1>GSD Engine Dashboard</h1>
  <button class="gsd-btn" onclick="refresh()">Refresh</button>
</div>

<div id="engine-banner" class="engine-banner">
  <span id="engine-state" class="engine-state">—</span>
  <span id="engine-detail" class="engine-detail"></span>
</div>

<div class="grid">
  <!-- Health Gauge -->
  <div class="card">
    <h2>Health Score</h2>
    <div class="health-gauge">
      <div class="gauge">
        <svg width="140" height="140" viewBox="0 0 140 140">
          <circle cx="70" cy="70" r="60" fill="none" stroke="var(--border)" stroke-width="12"/>
          <circle id="gauge-arc" cx="70" cy="70" r="60" fill="none" stroke="var(--green)"
            stroke-width="12" stroke-linecap="round"
            stroke-dasharray="0 377" />
        </svg>
        <div id="gauge-text" class="gauge-text">—</div>
      </div>
      <div class="health-stats">
        <div class="stat"><span class="label">Satisfied</span><span id="stat-satisfied">—</span></div>
        <div class="stat"><span class="label">Partial</span><span id="stat-partial">—</span></div>
        <div class="stat"><span class="label">Not Started</span><span id="stat-notstarted">—</span></div>
        <div class="stat"><span class="label">Total</span><span id="stat-total">—</span></div>
        <div class="stat"><span class="label">Iteration</span><span id="stat-iteration">—</span></div>
      </div>
    </div>
    <div id="health-sparkline" class="sparkline"></div>
  </div>

  <!-- Requirements Burndown -->
  <div class="card">
    <h2>Requirements by Phase</h2>
    <div id="req-burndown" class="req-burndown"></div>
    <div class="legend">
      <div class="legend-item"><div class="legend-dot" style="background:var(--green)"></div> Satisfied</div>
      <div class="legend-item"><div class="legend-dot" style="background:var(--yellow)"></div> Partial</div>
      <div class="legend-item"><div class="legend-dot" style="background:var(--red)"></div> Not Started</div>
    </div>
  </div>

  <!-- Phase Progress -->
  <div class="card grid-full">
    <h2>Current Phase</h2>
    <div id="phase-track" class="phase-track">
      <div class="phase-step" data-phase="code-review">Code Review</div>
      <div class="phase-step" data-phase="research">Research</div>
      <div class="phase-step" data-phase="plan">Plan</div>
      <div class="phase-step" data-phase="execute">Execute</div>
      <div class="phase-step" data-phase="verify">Verify</div>
    </div>
  </div>

  <!-- Agent Cost Chart -->
  <div class="card">
    <h2>Token Costs by Agent</h2>
    <div id="cost-chart" class="bar-chart"></div>
  </div>

  <!-- Agent Timeline -->
  <div class="card">
    <h2>Agent Activity</h2>
    <div id="timeline" class="timeline"></div>
  </div>

  <!-- Queue / Current Work -->
  <div class="card grid-full">
    <h2>Current Work Queue</h2>
    <div id="queue-content"></div>
  </div>
</div>

<script nonce="${nonce}">
  const vscode = acquireVsCodeApi();
  let currentData = ${JSON.stringify(snapshot)};

  function refresh() { vscode.postMessage({ type: 'refresh' }); }

  window.addEventListener('message', event => {
    const msg = event.data;
    if (msg.type === 'update') {
      currentData = msg.data;
      render(currentData);
    }
  });

  function render(data) {
    renderEngine(data.engine);
    renderHealth(data.health);
    renderBurndown(data.matrix);
    renderPhase(data.engine);
    renderCosts(data.costs);
    renderTimeline(data.handoffs);
    renderQueue(data.queue);
    renderSparkline(data.handoffs);
  }

  function renderEngine(engine) {
    const el = document.getElementById('engine-state');
    const detail = document.getElementById('engine-detail');
    if (!engine) {
      el.textContent = 'OFFLINE';
      el.className = 'engine-state';
      detail.textContent = 'Engine not running. Use Ctrl+Shift+G C to start.';
      return;
    }
    el.textContent = engine.state;
    el.className = 'engine-state ' + engine.state;
    const parts = [];
    if (engine.phase) parts.push('Phase: ' + engine.phase);
    if (engine.agent) parts.push('Agent: ' + engine.agent);
    parts.push('Iter: ' + engine.iteration);
    if (engine.attempt) parts.push('Attempt: ' + engine.attempt);
    if (engine.elapsed_minutes) parts.push(engine.elapsed_minutes + 'm elapsed');
    detail.textContent = parts.join(' · ');
  }

  function renderHealth(health) {
    if (!health) return;
    const pct = health.health_score;
    const circumference = 2 * Math.PI * 60;
    const dashLen = (pct / 100) * circumference;
    const arc = document.getElementById('gauge-arc');
    arc.setAttribute('stroke-dasharray', dashLen + ' ' + circumference);
    arc.setAttribute('stroke', pct >= 90 ? 'var(--green)' : pct >= 50 ? 'var(--yellow)' : 'var(--red)');

    document.getElementById('gauge-text').textContent = pct.toFixed(1) + '%';
    document.getElementById('stat-satisfied').textContent = health.satisfied;
    document.getElementById('stat-partial').textContent = health.partial;
    document.getElementById('stat-notstarted').textContent = health.not_started;
    document.getElementById('stat-total').textContent = health.total_requirements;
    document.getElementById('stat-iteration').textContent = health.iteration;
  }

  function renderBurndown(matrix) {
    const container = document.getElementById('req-burndown');
    if (!matrix || !matrix.requirements) { container.innerHTML = '<em>No data</em>'; return; }

    const phases = {};
    matrix.requirements.forEach(r => {
      const p = r.sdlc_phase || 'Unassigned';
      if (!phases[p]) phases[p] = { satisfied: 0, partial: 0, not_started: 0, total: 0 };
      phases[p][r.status]++;
      phases[p].total++;
    });

    container.innerHTML = Object.entries(phases).map(([phase, c]) => {
      const sPct = (c.satisfied / c.total * 100).toFixed(1);
      const pPct = (c.partial / c.total * 100).toFixed(1);
      const nPct = (c.not_started / c.total * 100).toFixed(1);
      return '<div class="req-row">' +
        '<span class="label">' + phase + '</span>' +
        '<div class="req-bar-track">' +
          '<div class="req-bar-seg" style="width:' + sPct + '%;background:var(--green)"></div>' +
          '<div class="req-bar-seg" style="width:' + pPct + '%;background:var(--yellow)"></div>' +
          '<div class="req-bar-seg" style="width:' + nPct + '%;background:var(--red)"></div>' +
        '</div>' +
        '<span class="req-count">' + c.satisfied + '/' + c.total + '</span>' +
      '</div>';
    }).join('');
  }

  function renderPhase(engine) {
    const steps = document.querySelectorAll('.phase-step');
    const phaseOrder = ['code-review', 'research', 'plan', 'execute', 'verify'];
    const currentIdx = engine ? phaseOrder.indexOf(engine.phase) : -1;

    steps.forEach((step, i) => {
      step.classList.remove('active', 'done');
      if (i === currentIdx) step.classList.add('active');
      else if (i < currentIdx) step.classList.add('done');
    });
  }

  function renderCosts(costs) {
    const container = document.getElementById('cost-chart');
    if (!costs || !costs.runs) { container.innerHTML = '<em>No cost data</em>'; return; }

    const byAgent = {};
    costs.runs.forEach(run => {
      run.details.forEach(d => {
        if (!byAgent[d.agent]) byAgent[d.agent] = 0;
        byAgent[d.agent] += d.cost_usd;
      });
    });

    const maxCost = Math.max(...Object.values(byAgent), 0.01);
    const colors = { claude: 'var(--orange)', codex: 'var(--green)', gemini: 'var(--blue)',
                     kimi: 'var(--purple)', deepseek: 'var(--yellow)', glm5: '#88c0d0', minimax: '#b48ead' };

    container.innerHTML = Object.entries(byAgent).map(([agent, cost]) => {
      const h = Math.max((cost / maxCost) * 150, 4);
      const c = colors[agent] || 'var(--accent)';
      return '<div class="bar-group">' +
        '<div class="bar" style="height:' + h + 'px;background:' + c + '" data-tooltip="$' + cost.toFixed(2) + '"></div>' +
        '<div class="bar-label">' + agent + '</div>' +
      '</div>';
    }).join('');
  }

  function renderTimeline(handoffs) {
    const container = document.getElementById('timeline');
    if (!handoffs || handoffs.length === 0) { container.innerHTML = '<em>No activity</em>'; return; }

    const recent = handoffs.slice(-15).reverse();
    container.innerHTML = recent.map(h => {
      const delta = h.health_after - h.health_before;
      const deltaStr = delta > 0 ? '+' + delta.toFixed(1) + '%' : delta < 0 ? delta.toFixed(1) + '%' : '±0%';
      const deltaColor = delta > 0 ? 'var(--green)' : delta < 0 ? 'var(--red)' : 'var(--fg)';
      return '<div class="timeline-entry">' +
        '<div class="timeline-dot ' + h.status + '"></div>' +
        '<span class="timeline-agent">' + h.agent + '</span>' +
        '<span class="timeline-phase">' + h.phase + '</span>' +
        '<span>Iter ' + h.iteration + '</span>' +
        '<span class="timeline-delta" style="color:' + deltaColor + '">' + deltaStr + '</span>' +
        '<span>' + h.duration_seconds + 's</span>' +
      '</div>';
    }).join('');
  }

  function renderQueue(queue) {
    const container = document.getElementById('queue-content');
    if (!queue || !queue.batch || queue.batch.length === 0) {
      container.innerHTML = '<em>Queue empty</em>';
      return;
    }

    const priorityColors = { critical: 'var(--red)', high: 'var(--orange)', medium: 'var(--yellow)', low: 'var(--fg)' };

    container.innerHTML = '<table style="width:100%;border-collapse:collapse;font-size:12px">' +
      '<tr style="opacity:0.6"><th style="text-align:left;padding:4px">ID</th><th style="text-align:left;padding:4px">Description</th>' +
      '<th style="padding:4px">Priority</th><th style="padding:4px">Pattern</th><th style="padding:4px">Effort</th></tr>' +
      queue.batch.map(item => {
        const pc = priorityColors[item.priority] || 'var(--fg)';
        return '<tr style="border-top:1px solid var(--border)">' +
          '<td style="padding:4px;font-weight:bold">' + item.req_id + '</td>' +
          '<td style="padding:4px">' + item.description + '</td>' +
          '<td style="padding:4px;text-align:center;color:' + pc + '">' + item.priority + '</td>' +
          '<td style="padding:4px;text-align:center">' + item.pattern + '</td>' +
          '<td style="padding:4px;text-align:center">' + item.estimated_effort + '</td>' +
        '</tr>';
      }).join('') + '</table>';
  }

  function renderSparkline(handoffs) {
    const container = document.getElementById('health-sparkline');
    if (!handoffs || handoffs.length === 0) { container.innerHTML = ''; return; }

    // Show health_after for each handoff as a sparkline
    const points = handoffs.map(h => h.health_after).filter(v => v !== undefined);
    if (points.length === 0) return;
    const max = 100;

    container.innerHTML = points.map(v => {
      const h = Math.max((v / max) * 36, 2);
      const color = v >= 90 ? 'var(--green)' : v >= 50 ? 'var(--yellow)' : 'var(--red)';
      return '<div class="spark-bar" style="height:' + h + 'px;background:' + color + '" title="' + v.toFixed(1) + '%"></div>';
    }).join('');
  }

  // Initial render
  render(currentData);
</script>
</body>
</html>`;
  }
}

function getNonce(): string {
  let text = '';
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  for (let i = 0; i < 32; i++) {
    text += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return text;
}
