<script lang="ts">
  import { invoke } from '../lib/ipc';
  import type { DiagnosticItem, MigrationBackup, ScannedCandidateGroup, ThemeDef, AppUpdateInfo } from '../lib/types';

  interface Props {
    flavour: string;
    currentTheme: string;
    density: 'comfortable' | 'compact';
    onThemeChange: (theme: string) => void;
    onDensityChange: (density: 'comfortable' | 'compact') => void;
    onExportList: () => void;
    onImportList: () => void;
    onRequestUninstall: () => void;
  }

  let {
    flavour,
    currentTheme,
    density,
    onThemeChange,
    onDensityChange,
    onExportList,
    onImportList,
    onRequestUninstall,
  }: Props = $props();

  // Settings State
  let includeBeta = $state(false);
  let backgroundUpdates = $state(true);
  let backgroundInterval = $state('120');
  let startWithWindows = $state(false);
  let autoAppUpdate = $state(true);
  let showTestRealms = $state(false);

  // Advanced CurseForge
  let cfAdFilter = $state(true);
  let cfSearchOnly = $state(true);

  // GitHub Token (write-only)
  let hasGithubToken = $state(false);
  let githubTokenInput = $state('');
  let githubTokenSuccess = $state<string | null>(null);

  // Untracked folders
  let untrackedGroups = $state<ScannedCandidateGroup[]>([]);
  let scanningUntracked = $state(false);

  // Diagnostics
  let diagnostics = $state<DiagnosticItem[]>([]);
  let runningDiagnostics = $state(false);
  let diagnosticsReport = $state<string | null>(null);

  // Migration backups
  let migrationBackups = $state<MigrationBackup[]>([]);
  let loadingBackups = $state(false);

  // Advanced accordion
  let advancedOpen = $state(false);

  // App Update State
  let appUpdateInfo = $state<AppUpdateInfo | null>(null);
  let checkingAppUpdate = $state(false);
  let installingAppUpdate = $state(false);
  let updateCheckError = $state<string | null>(null);

  async function handleCheckAppUpdate() {
    checkingAppUpdate = true;
    updateCheckError = null;
    try {
      const res = await invoke<AppUpdateInfo>('app_update_check');
      appUpdateInfo = res;
    } catch (err: any) {
      updateCheckError = String(err);
    } finally {
      checkingAppUpdate = false;
    }
  }

  async function handleInstallAppUpdate() {
    installingAppUpdate = true;
    updateCheckError = null;
    try {
      await invoke('app_update_install');
    } catch (err: any) {
      updateCheckError = String(err);
      installingAppUpdate = false;
    }
  }

  // All 16 Themes definitions for the swatch grid
  const themes: ThemeDef[] = [
    { slug: 'tokyo-rain', name: 'Tokyo Rain', scheme: 'dark', swBg: '#12151f', swBg2: '#0b0d14', swAccent: '#ff5aa8', swText: '#e8ecf5' },
    { slug: 'arcane-library', name: 'Arcane Library', scheme: 'dark', swBg: '#121022', swBg2: '#0a0912', swAccent: '#88afff', swText: '#f4eedd' },
    { slug: 'vaporwave', name: 'Vaporwave', scheme: 'dark', swBg: '#1a0b2e', swBg2: '#12081f', swAccent: '#ff71ce', swText: '#f3e9ff' },
    { slug: 'lofi', name: 'Lofi', scheme: 'dark', swBg: '#1e1c1b', swBg2: '#161413', swAccent: '#ff9d5c', swText: '#eee7de' },
    { slug: 'dark', name: 'Classic Dark', scheme: 'dark', swBg: '#141416', swBg2: '#0d0d0f', swAccent: '#ff8a3d', swText: '#eeeeee' },
    { slug: 'light', name: 'Clean Light', scheme: 'light', swBg: '#ffffff', swBg2: '#f5f5f7', swAccent: '#b85400', swText: '#18181a' },
    { slug: 'terminal-green', name: 'Terminal Green', scheme: 'dark', swBg: '#091509', swBg2: '#040b04', swAccent: '#33ff33', swText: '#d8ffd8' },
    { slug: 'arctic-ice', name: 'Arctic Ice', scheme: 'dark', swBg: '#0a1622', swBg2: '#050c14', swAccent: '#6ee7ff', swText: '#e8f6ff' },
    { slug: 'art-deco-gold', name: 'Art Deco Gold', scheme: 'dark', swBg: '#14120e', swBg2: '#0d0c09', swAccent: '#f0c665', swText: '#f7f1e1' },
    { slug: 'alpine-dawn', name: 'Alpine Dawn', scheme: 'dark', swBg: '#16131c', swBg2: '#0f0c14', swAccent: '#f28b74', swText: '#f5edf2' },
    { slug: 'matcha', name: 'Matcha', scheme: 'dark', swBg: '#111713', swBg2: '#0a0f0c', swAccent: '#8ec47a', swText: '#ecf4ea' },
    { slug: 'desert-night', name: 'Desert Night', scheme: 'dark', swBg: '#1c1313', swBg2: '#130b0b', swAccent: '#f4804d', swText: '#faeee9' },
    { slug: 'brushed-steel', name: 'Brushed Steel', scheme: 'dark', swBg: '#181b20', swBg2: '#101317', swAccent: '#8fa4be', swText: '#ecf0f5' },
    { slug: 'aurora-sky', name: 'Aurora Sky', scheme: 'dark', swBg: '#08171f', swBg2: '#040e14', swAccent: '#48e5c2', swText: '#e6fbf5' },
    { slug: 'strawberry-cream', name: 'Strawberry Cream', scheme: 'light', swBg: '#ffffff', swBg2: '#fff2f4', swAccent: '#a82c48', swText: '#331c22' },
    { slug: 'snow-day', name: 'Snow Day', scheme: 'light', swBg: '#ffffff', swBg2: '#eef1f2', swAccent: '#8f5a2e', swText: '#1c2b33' },
  ];

  let initialLoaded = $state(false);

  async function loadInitialSettings() {
    try {
      const s = await invoke<Record<string, any>>('get_settings');
      if (s) {
        if (s.releaseType !== undefined) includeBeta = Number(s.releaseType) >= 2;
        else if (s.includeBeta !== undefined) includeBeta = Boolean(s.includeBeta);

        if (s.backgroundUpdates !== undefined) backgroundUpdates = Boolean(s.backgroundUpdates);
        if (s.backgroundIntervalMinutes) backgroundInterval = String(s.backgroundIntervalMinutes);
        if (s.runAtStartup !== undefined) startWithWindows = Boolean(s.runAtStartup);
        else if (s.startWithWindows !== undefined) startWithWindows = Boolean(s.startWithWindows);

        if (s.appUpdateAutoInstall !== undefined) autoAppUpdate = Boolean(s.appUpdateAutoInstall);
        if (s.showTestRealms !== undefined) showTestRealms = Boolean(s.showTestRealms);
        if (s.adFilter !== undefined) cfAdFilter = Boolean(s.adFilter);
        if (s.cfFocus !== undefined) cfSearchOnly = Boolean(s.cfFocus);
        if (s.hasGithubToken !== undefined) hasGithubToken = Boolean(s.hasGithubToken);
      }
    } catch {
      // Mock fallback
    } finally {
      initialLoaded = true;
    }

    scanUntracked();
  }

  async function updateSetting(key: string, value: any) {
    try {
      await invoke('update_settings', { key, value });
    } catch (err) {
      console.warn(`Failed persisting setting ${key}:`, err);
    }
  }

  async function scanUntracked() {
    scanningUntracked = true;
    try {
      untrackedGroups = await invoke<ScannedCandidateGroup[]>('scan_untracked', { flavour });
    } catch {
      untrackedGroups = [];
    } finally {
      scanningUntracked = false;
    }
  }

  async function adoptFolder(group: ScannedCandidateGroup) {
    try {
      await invoke('adopt_untracked', { flavour, candidate: group });
      await scanUntracked();
    } catch (err) {
      console.error('Failed to adopt:', err);
    }
  }

  async function adoptAll() {
    try {
      await invoke('adopt_all_untracked', { flavour });
      await scanUntracked();
    } catch (err) {
      console.error('Failed to adopt all:', err);
    }
  }

  async function saveGithubToken() {
    if (!githubTokenInput.trim()) return;
    try {
      await invoke('update_settings', {
        key: 'githubToken',
        value: githubTokenInput.trim(),
      });
      hasGithubToken = true;
      githubTokenInput = '';
      githubTokenSuccess = 'Token saved securely.';
      setTimeout(() => (githubTokenSuccess = null), 4000);
    } catch (err) {
      console.error('Failed saving token:', err);
    }
  }

  async function removeGithubToken() {
    try {
      await invoke('update_settings', {
        key: 'githubToken',
        value: '',
      });
      hasGithubToken = false;
      githubTokenSuccess = 'Token removed.';
      setTimeout(() => (githubTokenSuccess = null), 4000);
    } catch (err) {
      console.error('Failed removing token:', err);
    }
  }

  async function runDiagnostics() {
    runningDiagnostics = true;
    try {
      diagnostics = await invoke<DiagnosticItem[]>('run_diagnostics');
      diagnosticsReport = diagnostics.map(d => `[${d.ok ? 'PASS' : 'FAIL'}] ${d.name}: ${d.detail}`).join('\n');
    } catch (err) {
      console.error('Diagnostics failed:', err);
    } finally {
      runningDiagnostics = false;
    }
  }

  function copyDiagnosticsReport() {
    if (diagnosticsReport) {
      navigator.clipboard.writeText(diagnosticsReport);
    }
  }

  async function openTarget(target: string) {
    try {
      await invoke('open_target', { what: target, args: [flavour] });
    } catch (err) {
      console.error('Open target failed:', err);
    }
  }

  loadInitialSettings();
</script>

<div class="settings-view">
  <div class="settings-content">
    <h1 class="view-title">Settings</h1>

    <!-- 1. Updates Section -->
    <section class="settings-card">
      <h2 class="card-heading">Addon Updates</h2>
      <div class="setting-row">
        <label class="toggle-control">
          <input
            type="checkbox"
            bind:checked={includeBeta}
            onchange={() => updateSetting('releaseType', includeBeta ? 2 : 1)}
          />
          <span class="toggle-text">Include beta versions for addon checks</span>
        </label>
      </div>

      <div class="setting-row">
        <label class="toggle-control">
          <input
            type="checkbox"
            bind:checked={backgroundUpdates}
            onchange={() => invoke('set_background_updates', { enabled: backgroundUpdates }).catch(() => {})}
          />
          <span class="toggle-text">Update addons automatically in the background</span>
        </label>
      </div>

      {#if backgroundUpdates}
        <div class="setting-row indent">
          <label for="interval-select" class="control-label">Check interval:</label>
          <select
            id="interval-select"
            class="form-select"
            bind:value={backgroundInterval}
            onchange={() => {
              const mins = parseInt(backgroundInterval, 10);
              if (!isNaN(mins)) {
                updateSetting('backgroundIntervalMinutes', mins);
              }
            }}
          >
            <option value="60">Every hour</option>
            <option value="120">Every 2 hours (default)</option>
            <option value="240">Every 4 hours</option>
            <option value="480">Every 8 hours</option>
            <option value="1440">Once a day</option>
          </select>
        </div>
      {/if}

      <div class="setting-row">
        <label class="toggle-control">
          <input
            type="checkbox"
            bind:checked={startWithWindows}
            onchange={() => {
              if (startWithWindows) {
                invoke('autostart_enable').catch(() => {});
                backgroundUpdates = true;
                invoke('set_background_updates', { enabled: true }).catch(() => {});
              } else {
                invoke('autostart_disable').catch(() => {});
              }
            }}
          />
          <span class="toggle-text">Start Furphy with Windows (in system tray)</span>
        </label>
      </div>
    </section>

    <!-- 2. App Updates Section -->
    <section class="settings-card">
      <h2 class="card-heading">Furphy App Updates</h2>
      <div class="setting-row">
        <label class="toggle-control">
          <input
            type="checkbox"
            bind:checked={autoAppUpdate}
            onchange={() => updateSetting('appUpdateAutoInstall', autoAppUpdate)}
          />
          <span class="toggle-text">Install Furphy app updates automatically</span>
        </label>
      </div>
      <div class="setting-actions">
        <button
          type="button"
          class="btn-secondary"
          disabled={checkingAppUpdate}
          onclick={handleCheckAppUpdate}
        >
          {checkingAppUpdate ? 'Checking for updates...' : 'Check for updates now'}
        </button>
      </div>

      {#if appUpdateInfo}
        <div class="app-update-status-panel">
          {#if appUpdateInfo.has_update}
            <div class="update-found-msg">
              <strong>Version {appUpdateInfo.update_version} is available.</strong>
            </div>
            {#if appUpdateInfo.release_notes}
              <div class="update-notes-box">
                <pre>{appUpdateInfo.release_notes}</pre>
              </div>
            {/if}
            <div class="setting-actions" style="margin-top: 8px;">
              <button
                type="button"
                class="btn-primary"
                disabled={installingAppUpdate}
                onclick={handleInstallAppUpdate}
              >
                {installingAppUpdate ? 'Installing...' : 'Install now'}
              </button>
            </div>
          {:else}
            <div class="up-to-date-msg">
              Furphy Addon Manager is up to date (current: v{appUpdateInfo.current_version}).
            </div>
          {/if}
        </div>
      {/if}

      {#if updateCheckError}
        <div class="error-banner" style="margin-top: 8px;">
          {updateCheckError}
        </div>
      {/if}
    </section>

    <!-- 3. Appearance: Density & 16-Theme Grid -->
    <section class="settings-card">
      <h2 class="card-heading">Appearance</h2>

      <div class="setting-row">
        <span class="control-label">Table Spacing:</span>
        <div class="segmented-control">
          <button
            type="button"
            class="segment-btn"
            class:active={density === 'comfortable'}
            onclick={() => onDensityChange('comfortable')}
          >
            Comfortable
          </button>
          <button
            type="button"
            class="segment-btn"
            class:active={density === 'compact'}
            onclick={() => onDensityChange('compact')}
          >
            Compact
          </button>
        </div>
      </div>

      <div class="theme-selection">
        <div class="control-label theme-label">Theme Palette (16 Custom Styles):</div>
        <div class="theme-grid" role="radiogroup" aria-label="Theme selection">
          {#each themes as t (t.slug)}
            <button
              type="button"
              role="radio"
              aria-checked={currentTheme === t.slug}
              class="theme-swatch-card"
              class:selected={currentTheme === t.slug}
              onclick={() => onThemeChange(t.slug)}
              title={t.name}
            >
              <div class="swatch-preview" style:background={t.swBg}>
                <div class="swatch-bar" style:background={t.swBg2}></div>
                <div class="swatch-accent" style:background={t.swAccent}></div>
                <div class="swatch-text" style:color={t.swText}>Aa</div>
              </div>
              <span class="swatch-name">{t.name}</span>
            </button>
          {/each}
        </div>
      </div>
    </section>

    <!-- 4. Addons Furphy isn't managing yet -->
    <section class="settings-card">
      <div class="card-header-row">
        <div>
          <h2 class="card-heading">Addons Furphy Isn’t Managing Yet</h2>
          <p class="card-subtitle">
            Unmanaged folders discovered in your World of Warcraft AddOns directory.
          </p>
        </div>
        <div class="header-btns">
          <button type="button" class="btn-secondary" onclick={scanUntracked} disabled={scanningUntracked}>
            {scanningUntracked ? 'Scanning…' : 'Scan AddOns Folder'}
          </button>
          {#if untrackedGroups.length > 0}
            <button type="button" class="btn-accent" onclick={adoptAll}>
              Manage All ({untrackedGroups.length})
            </button>
          {/if}
        </div>
      </div>

      {#if untrackedGroups.length === 0}
        <div class="empty-untracked">
          <span>All AddOns in {flavour} are tracked or recognized.</span>
        </div>
      {:else}
        <div class="untracked-list">
          {#each untrackedGroups as group (group.name)}
            <div class="untracked-item">
              <div class="untracked-info">
                <span class="untracked-name">{group.name}</span>
                {#if group.version}
                  <span class="untracked-ver font-mono">v{group.version}</span>
                {/if}
                <span class="untracked-folders font-mono">
                  {group.folders.join(', ')}
                </span>
              </div>
              <button
                type="button"
                class="btn-sm btn-accent"
                onclick={() => adoptFolder(group)}
              >
                Manage
              </button>
            </div>
          {/each}
        </div>
      {/if}
    </section>

    <!-- 5. Advanced Accordion -->
    <section class="settings-card advanced-section">
      <button
        type="button"
        class="advanced-toggle"
        onclick={() => (advancedOpen = !advancedOpen)}
        aria-expanded={advancedOpen}
      >
        <span class="toggle-icon">{advancedOpen ? '▼' : '►'}</span>
        <h2 class="card-heading advanced-title">Advanced Settings</h2>
      </button>

      {#if advancedOpen}
        <div class="advanced-body">
          <!-- CurseForge Pane Settings -->
          <div class="advanced-group">
            <h3>CurseForge Browser Pane</h3>
            <label class="toggle-control">
              <input
                type="checkbox"
                bind:checked={cfAdFilter}
                onchange={() => updateSetting('adFilter', cfAdFilter)}
              />
              <span class="toggle-text">Filter ads and telemetry on embedded CurseForge pages</span>
            </label>
            <label class="toggle-control">
              <input
                type="checkbox"
                bind:checked={cfSearchOnly}
                onchange={() => updateSetting('cfFocus', cfSearchOnly)}
              />
              <span class="toggle-text">Focus mode: hide headers and navigation banners</span>
            </label>
          </div>

          <!-- GitHub Token -->
          <div class="advanced-group">
            <h3>GitHub Addon Access Token</h3>
            <p class="setting-desc">
              Recommended to prevent GitHub API rate limits (60 requests/hr) and support private repos.
            </p>
            <div class="token-status">
              Status:
              <strong class={hasGithubToken ? 'text-success' : 'text-muted'}>
                {hasGithubToken ? 'Active token configured' : 'No token set'}
              </strong>
            </div>
            <div class="token-form">
              <input
                type="password"
                class="form-input"
                placeholder="ghp_xxxxxxxxxxxxxxxxxxxx"
                bind:value={githubTokenInput}
              />
              <button type="button" class="btn-primary" onclick={saveGithubToken}>
                Save Token
              </button>
              {#if hasGithubToken}
                <button type="button" class="btn-secondary" onclick={removeGithubToken}>
                  Remove
                </button>
              {/if}
            </div>
            {#if githubTokenSuccess}
              <div class="success-notice">{githubTokenSuccess}</div>
            {/if}
          </div>

          <!-- WoW Versions -->
          <div class="advanced-group">
            <h3>World of Warcraft Versions</h3>
            <label class="toggle-control">
              <input
                type="checkbox"
                bind:checked={showTestRealms}
                onchange={() => updateSetting('showTestRealms', showTestRealms)}
              />
              <span class="toggle-text">Show test realms (PTR, XPTR, Beta clients) in version switcher</span>
            </label>
          </div>

          <!-- Open Folders -->
          <div class="advanced-group">
            <h3>App Folders & Locations</h3>
            <div class="folder-btns">
              <button type="button" class="btn-secondary" onclick={() => openTarget('wowfolder')}>
                Open WoW Folder
              </button>
              <button type="button" class="btn-secondary" onclick={() => openTarget('addons')}>
                Open AddOns Folder
              </button>
              <button type="button" class="btn-secondary" onclick={() => openTarget('datafolder')}>
                Open Data Folder
              </button>
              <button type="button" class="btn-secondary" onclick={() => openTarget('logs')}>
                Open Logs Folder
              </button>
            </div>
          </div>

          <!-- Export & Import -->
          <div class="advanced-group">
            <h3>Backup & Transfer</h3>
            <div class="folder-btns">
              <button type="button" class="btn-primary" onclick={onExportList}>
                Export Addon List (/2 format)
              </button>
              <button type="button" class="btn-secondary" onclick={onImportList}>
                Import Addon List…
              </button>
            </div>
          </div>

          <!-- Diagnostics -->
          <div class="advanced-group">
            <h3>Diagnostics & Health</h3>
            <div class="diagnostics-bar">
              <button
                type="button"
                class="btn-secondary"
                onclick={runDiagnostics}
                disabled={runningDiagnostics}
              >
                {runningDiagnostics ? 'Running…' : 'Run Diagnostics'}
              </button>
              {#if diagnosticsReport}
                <button type="button" class="btn-secondary" onclick={copyDiagnosticsReport}>
                  Copy Report
                </button>
              {/if}
            </div>

            {#if diagnostics.length > 0}
              <div class="diagnostics-table">
                {#each diagnostics as diag (diag.name)}
                  <div class="diag-row">
                    <span class="diag-status" class:pass={diag.ok} class:fail={!diag.ok}>
                      {diag.ok ? 'PASS' : 'FAIL'}
                    </span>
                    <span class="diag-name">{diag.name}:</span>
                    <span class="diag-detail">{diag.detail}</span>
                  </div>
                {/each}
              </div>
            {/if}
          </div>

          <!-- Migration Backups -->
          <div class="advanced-group">
            <h3>Upgrade Safety Backups</h3>
            <div class="folder-btns">
              <button
                type="button"
                class="btn-secondary"
                onclick={async () => {
                  migrationBackups = await invoke<MigrationBackup[]>('list_migration_backups');
                }}
              >
                Check Upgrade Copies
              </button>
              {#if migrationBackups.length > 0}
                <button
                  type="button"
                  class="btn-danger"
                  onclick={async () => {
                    await invoke('delete_migration_backups');
                    migrationBackups = [];
                  }}
                >
                  Delete Upgrade Copies
                </button>
              {/if}
            </div>
          </div>

          <!-- Danger Zone: Uninstall -->
          <div class="advanced-group danger-zone">
            <h3>Uninstall</h3>
            <p class="setting-desc">
              Removes Furphy Addon Manager from your system. Your addons and SavedVariables are kept intact.
            </p>
            <button type="button" class="btn-danger" onclick={onRequestUninstall}>
              Uninstall Furphy Addon Manager…
            </button>
          </div>
        </div>
      {/if}
    </section>
  </div>
</div>

<style>
  .settings-view {
    height: 100%;
    overflow-y: auto;
    padding: 1.5rem;
    box-sizing: border-box;
  }

  .settings-content {
    max-width: 800px;
    margin: 0 auto;
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
  }

  .view-title {
    margin: 0;
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--text);
  }

  .settings-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius, 8px);
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .card-heading {
    margin: 0;
    font-size: 1.1rem;
    font-weight: 700;
    color: var(--text);
  }

  .card-subtitle {
    margin: 0.25rem 0 0 0;
    font-size: 0.85rem;
    color: var(--text-muted);
  }

  .card-header-row {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 1rem;
  }

  .header-btns {
    display: flex;
    gap: 0.5rem;
  }

  .setting-row {
    display: flex;
    align-items: center;
    gap: 1rem;
  }

  .setting-row.indent {
    padding-left: 1.5rem;
  }

  .control-label {
    font-size: 0.85rem;
    color: var(--text);
    font-weight: 600;
  }

  .setting-desc {
    margin: 0;
    font-size: 0.85rem;
    color: var(--text-muted);
    line-height: 1.4;
  }

  .toggle-control {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    font-size: 0.9rem;
    color: var(--text);
    cursor: pointer;
    user-select: none;
  }

  .toggle-control input[type="checkbox"] {
    width: 16px;
    height: 16px;
    accent-color: var(--accent);
  }

  .segmented-control {
    display: flex;
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    overflow: hidden;
  }

  .segment-btn {
    background: none;
    border: none;
    color: var(--text-muted);
    padding: 0.35rem 0.85rem;
    font-size: 0.85rem;
    cursor: pointer;
  }

  .segment-btn.active {
    background: var(--bg-3);
    color: var(--text);
    font-weight: 600;
  }

  .theme-selection {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .theme-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
    gap: 0.75rem;
  }

  .theme-swatch-card {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
    cursor: pointer;
    text-align: left;
    transition: border-color var(--fast), transform var(--fast);
  }

  .theme-swatch-card:hover {
    border-color: var(--border-hover);
    transform: translateY(-1px);
  }

  .theme-swatch-card.selected {
    border-color: var(--accent);
    box-shadow: 0 0 0 1px var(--accent);
  }

  .theme-swatch-card:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .swatch-preview {
    height: 38px;
    border-radius: 3px;
    position: relative;
    overflow: hidden;
    display: flex;
    align-items: center;
    justify-content: center;
    border: 1px solid rgba(255, 255, 255, 0.1);
  }

  .swatch-bar {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 8px;
  }

  .swatch-accent {
    position: absolute;
    bottom: 4px;
    left: 6px;
    width: 10px;
    height: 10px;
    border-radius: 50%;
  }

  .swatch-text {
    font-size: 0.75rem;
    font-weight: 700;
  }

  .swatch-name {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .empty-untracked {
    background: var(--bg-0);
    border: 1px dashed var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 1.25rem;
    text-align: center;
    color: var(--text-muted);
    font-size: 0.85rem;
  }

  .untracked-list {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .untracked-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    background: var(--bg-0);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-sm, 4px);
    padding: 0.6rem 0.85rem;
  }

  .untracked-info {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    overflow: hidden;
  }

  .untracked-name {
    font-weight: 600;
    font-size: 0.85rem;
    color: var(--text);
  }

  .untracked-ver {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .untracked-folders {
    font-size: 0.75rem;
    color: var(--text-faint);
  }

  .advanced-section {
    padding: 0;
    overflow: hidden;
  }

  .advanced-toggle {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    background: var(--bg-2);
    border: none;
    width: 100%;
    padding: 1rem 1.25rem;
    cursor: pointer;
    text-align: left;
    color: var(--text);
  }

  .advanced-toggle:focus-visible {
    outline: 2px solid var(--focus-ring);
  }

  .toggle-icon {
    font-size: 0.75rem;
    color: var(--text-muted);
  }

  .advanced-body {
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
    background: var(--bg-1);
    border-top: 1px solid var(--border);
  }

  .advanced-group {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
    border-bottom: 1px solid var(--border-soft);
    padding-bottom: 1.25rem;
  }

  .advanced-group:last-child {
    border-bottom: none;
    padding-bottom: 0;
  }

  .advanced-group h3 {
    margin: 0;
    font-size: 0.95rem;
    color: var(--text);
  }

  .token-status {
    font-size: 0.85rem;
    color: var(--text-muted);
  }

  .token-form {
    display: flex;
    gap: 0.5rem;
    max-width: 440px;
  }

  .folder-btns {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
  }

  .diagnostics-bar {
    display: flex;
    gap: 0.5rem;
  }

  .diagnostics-table {
    background: var(--bg-0);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-sm, 4px);
    padding: 0.65rem 0.85rem;
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
    font-family: monospace;
    font-size: 0.8rem;
  }

  .diag-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .diag-status {
    font-weight: 700;
    padding: 1px 4px;
    border-radius: 3px;
    font-size: 0.7rem;
  }

  .diag-status.pass {
    background: var(--success-tint);
    color: var(--success);
  }

  .diag-status.fail {
    background: var(--danger-tint);
    color: var(--danger);
  }

  .diag-name {
    color: var(--text);
  }

  .diag-detail {
    color: var(--text-muted);
  }

  .danger-zone {
    border-left: 3px solid var(--danger);
    padding-left: 0.75rem;
  }

  .success-notice {
    color: var(--success);
    font-size: 0.8rem;
  }

  .form-input, .form-select {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    color: var(--text);
    padding: 0.45rem 0.65rem;
    font-size: 0.85rem;
    outline: none;
  }

  .form-input:focus-visible, .form-select:focus-visible {
    border-color: var(--focus-ring);
  }

  .btn-primary, .btn-secondary, .btn-danger, .btn-accent, .btn-sm {
    border-radius: var(--radius-sm, 4px);
    font-size: 0.8rem;
    font-weight: 600;
    cursor: pointer;
    transition: background var(--fast);
  }

  .btn-primary {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    padding: 0.45rem 0.85rem;
  }

  .btn-primary:hover {
    background: var(--accent-hover);
  }

  .btn-secondary {
    background: var(--bg-3);
    color: var(--text);
    border: 1px solid var(--border);
    padding: 0.45rem 0.85rem;
  }

  .btn-secondary:hover {
    background: var(--border-hover);
  }

  .btn-danger {
    background: var(--danger);
    color: var(--danger-text);
    border: none;
    padding: 0.45rem 0.85rem;
  }

  .btn-danger:hover {
    background: var(--danger-hover);
  }

  .btn-accent {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    padding: 0.35rem 0.75rem;
  }

  .btn-sm {
    padding: 0.25rem 0.55rem;
    font-size: 0.75rem;
  }

  .text-success { color: var(--success); }
  .text-muted { color: var(--text-muted); }
  .font-mono { font-family: monospace; }
</style>
