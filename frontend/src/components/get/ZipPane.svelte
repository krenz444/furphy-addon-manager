<script lang="ts">
  import { isMockMode } from '../../lib/ipc';
  import type { InstallOutcome } from '../../lib/types';

  interface Props {
    flavour: string;
    displayLabel: string;
    destinationReason?: string | null;
    onInstallZip: (source: string, targetFlavour?: string) => Promise<InstallOutcome>;
  }

  let {
    flavour,
    displayLabel,
    destinationReason = null,
    onInstallZip,
  }: Props = $props();

  let zipInput = $state('');
  let isInstalling = $state(false);
  let isDragOver = $state(false);
  let resultMessage = $state<string | null>(null);
  let errorMessage = $state<string | null>(null);

  function handleFileDrop(e: Event) {
    const customEvent = e as CustomEvent<{ paths?: string[] }>;
    const paths = customEvent.detail?.paths;
    if (Array.isArray(paths)) {
      const zipPath = paths.find(
        (p) => typeof p === 'string' && p.toLowerCase().endsWith('.zip')
      );
      if (zipPath) {
        zipInput = zipPath;
        errorMessage = null;
        resultMessage = null;
      }
    }
  }

  function handleDragOver(e: DragEvent) {
    e.preventDefault();
    isDragOver = true;
  }

  function handleDragLeave() {
    isDragOver = false;
  }

  function handleDrop(e: DragEvent) {
    e.preventDefault();
    isDragOver = false;
    const files = e.dataTransfer?.files;
    if (files && files.length > 0) {
      const paths: string[] = [];
      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        const path = (file as unknown as { path?: string }).path || file.name;
        paths.push(path);
      }
      window.dispatchEvent(
        new CustomEvent('furphy:file-drop', { detail: { paths } })
      );
    }
  }

  $effect(() => {
    window.addEventListener('furphy:file-drop', handleFileDrop);

    let unlisten: (() => void) | null = null;
    let active = true;

    if (!isMockMode()) {
      import('@tauri-apps/api/webview')
        .then(({ getCurrentWebview }) => {
          if (!active) return;
          return getCurrentWebview().onDragDropEvent((event) => {
            if (event.payload.type === 'drop' && Array.isArray(event.payload.paths)) {
              window.dispatchEvent(
                new CustomEvent('furphy:file-drop', {
                  detail: { paths: event.payload.paths },
                })
              );
            }
          });
        })
        .then((unsub) => {
          if (active && unsub) {
            unlisten = unsub;
          } else if (unsub) {
            unsub();
          }
        })
        .catch(() => {
          // Failures swallowed as per design
        });
    }

    return () => {
      active = false;
      window.removeEventListener('furphy:file-drop', handleFileDrop);
      if (unlisten) {
        unlisten();
      }
    };
  });

  async function handleInstall() {
    const source = zipInput.trim();
    if (!source || Boolean(destinationReason) || isInstalling) return;

    isInstalling = true;
    errorMessage = null;
    resultMessage = null;

    try {
      const outcome = await onInstallZip(source, flavour);
      if (outcome && outcome.ok) {
        resultMessage = outcome.message || `Installed addon into ${displayLabel}.`;
        zipInput = '';
      } else {
        errorMessage = outcome?.message || 'Failed to install zip.';
      }
    } catch (err: unknown) {
      errorMessage = err instanceof Error ? err.message : String(err);
    } finally {
      isInstalling = false;
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') {
      handleInstall();
    }
  }
</script>

<div class="zip-pane">
  <div class="zip-card">
    <h2>Install from Zip</h2>
    <p class="zip-desc">
      Install an addon directly from a local .zip archive on this PC or from an https link.
    </p>

    <div
      class="zip-dropzone"
      class:drag-over={isDragOver}
      data-testid="zip-dropzone"
      ondragover={handleDragOver}
      ondragleave={handleDragLeave}
      ondrop={handleDrop}
      role="region"
      aria-label="Drop zip file here"
    >
      <div class="dropzone-content">
        <span class="dropzone-icon" aria-hidden="true">📦</span>
        <p class="dropzone-text">
          Drag and drop a <code>.zip</code> file here, or enter a path or link below.
        </p>
      </div>
    </div>

    <div class="zip-form">
      <label for="zip-input-field" class="form-label">
        Zip file path or https link:
      </label>
      <div class="input-row">
        <input
          id="zip-input-field"
          type="text"
          class="form-input"
          data-testid="zip-input"
          placeholder="e.g. C:\Downloads\Addon.zip or https://example.com/addon.zip"
          bind:value={zipInput}
          onkeydown={handleKeydown}
        />
        <button
          type="button"
          class="btn-primary"
          data-testid="zip-install-btn"
          disabled={isInstalling || !zipInput.trim() || Boolean(destinationReason)}
          onclick={handleInstall}
        >
          {#if isInstalling}
            <span class="btn-spinner" aria-hidden="true"></span>
            <span>Installing to {displayLabel}...</span>
          {:else}
            <span>Install to {displayLabel}</span>
          {/if}
        </button>
      </div>

      {#if destinationReason}
        <div class="form-reason" data-testid="zip-reason">
          {destinationReason}
        </div>
      {/if}

      {#if !zipInput.trim()}
        <div class="form-hint">
          Enter a path or an https link to a .zip file.
        </div>
      {/if}

      {#if errorMessage}
        <div class="form-error" data-testid="zip-error" role="alert">
          {errorMessage}
        </div>
      {/if}

      {#if resultMessage}
        <div class="form-success" data-testid="zip-result" role="status">
          {resultMessage}
        </div>
      {/if}
    </div>

    <div class="zip-notes">
      <h4>Direct Zip Installation</h4>
      <p>
        Furphy extracts and checks the archive for valid World of Warcraft addon folders containing <code>.toc</code> files. It safely places them into your <code>AddOns</code> folder and tracks them in the local database.
      </p>
    </div>
  </div>
</div>

<style>
  .zip-pane {
    display: flex;
    justify-content: center;
    padding: 2rem 1rem;
    width: 100%;
  }

  .zip-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: var(--radius-lg, 12px);
    padding: 2rem;
    max-width: 580px;
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
  }

  .zip-card h2 {
    margin: 0;
    font-size: 1.25rem;
    color: var(--text);
  }

  .zip-desc {
    margin: 0;
    font-size: 0.9rem;
    color: var(--text-muted);
    line-height: 1.45;
  }

  .zip-dropzone {
    border: 2px dashed var(--border);
    border-radius: var(--radius, 8px);
    padding: 1.5rem 1rem;
    text-align: center;
    background: var(--bg-0);
    transition: border-color var(--fast), background-color var(--fast);
  }

  .zip-dropzone.drag-over {
    border-color: var(--accent);
    background: color-mix(in srgb, var(--accent) 8%, var(--bg-0));
  }

  .dropzone-content {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.5rem;
  }

  .dropzone-icon {
    font-size: 1.75rem;
  }

  .dropzone-text {
    margin: 0;
    font-size: 0.85rem;
    color: var(--text-muted);
    line-height: 1.4;
  }

  .dropzone-text code {
    background: var(--bg-2);
    padding: 0.1rem 0.35rem;
    border-radius: 3px;
    color: var(--accent);
  }

  .zip-form {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .form-label {
    display: block;
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--text);
  }

  .input-row {
    display: flex;
    gap: 0.75rem;
  }

  .form-input {
    flex: 1;
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: var(--radius-sm, 4px);
    padding: 0.55rem 0.85rem;
    color: var(--text);
    font-size: 0.9rem;
    outline: none;
  }

  .form-input:focus-visible {
    border-color: var(--focus-ring);
    outline: 2px solid var(--focus-ring);
    outline-offset: 1px;
  }

  .btn-primary {
    background: var(--accent);
    color: var(--accent-text);
    border: none;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.85rem;
    font-weight: 600;
    cursor: pointer;
    padding: 0.55rem 1rem;
    white-space: nowrap;
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    transition: background var(--fast);
  }

  .btn-primary:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .btn-primary:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .btn-primary:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .btn-spinner {
    width: 12px;
    height: 12px;
    border: 2px solid var(--accent-text);
    border-top-color: transparent;
    border-radius: 50%;
    animation: spin 700ms linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .form-hint {
    font-size: 0.8rem;
    color: var(--text-muted);
  }

  .form-reason {
    font-size: 0.8rem;
    color: var(--warning);
    background: var(--warning-tint);
    border: 1px solid color-mix(in srgb, var(--warning) 30%, transparent);
    padding: 0.4rem 0.65rem;
    border-radius: var(--radius-sm, 4px);
  }

  .form-error {
    color: var(--danger);
    background: var(--danger-tint);
    border: 1px solid color-mix(in srgb, var(--danger) 30%, transparent);
    padding: 0.45rem 0.75rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.85rem;
  }

  .form-success {
    color: var(--success);
    background: var(--success-tint);
    border: 1px solid color-mix(in srgb, var(--success) 30%, transparent);
    padding: 0.45rem 0.75rem;
    border-radius: var(--radius-sm, 4px);
    font-size: 0.85rem;
  }

  .zip-notes {
    background: var(--bg-0);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius, 8px);
    padding: 1rem;
    font-size: 0.85rem;
    color: var(--text-muted);
  }

  .zip-notes h4 {
    margin: 0 0 0.4rem 0;
    color: var(--text);
    font-size: 0.9rem;
  }

  .zip-notes p {
    margin: 0;
    line-height: 1.4;
  }

  .zip-notes code {
    background: var(--bg-2);
    padding: 1px 4px;
    border-radius: 3px;
    color: var(--accent);
  }
</style>
