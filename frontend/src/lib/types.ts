export interface Addon {
  id: string;
  flavour: string;
  name: string | null;
  author: string | null;
  source: string | null;
  version: string | null;
  project_id: number | null;
  file_id: string | null;
  file_name: string | null;
  folders: string[];
  installed_at: string | null;
  adopted: boolean;
  ignore_updates: boolean;
  pinned_file_id: string | null;
  release_type: number | null;
  update_version?: string | null;
  update_file_id?: string | null;
  check_status?: string | null;
  error?: string | null;
  is_old_patch?: boolean;
  missing_deps?: string[];
  ignored_deps?: string[];
  wago_slug?: string | null;
  repo?: string | null;
}

export interface Flavour {
  id: string;
  folder: string;
  label: string;
  product: string | null;
  installed: boolean;
  client_build?: string | null;
  client_interface?: number | null;
  custom_root?: string | null;
  addons_path?: string | null;
}

export interface AppInfo {
  name: string;
  version: string;
  is_dev: boolean;
  identifier: string;
}

export interface Freshness {
  state: 'clean' | 'updates_ready' | 'checking' | 'not_checked' | 'failed' | string;
  checked_at: string | null;
  updates_count: number;
  last_error: string | null;
}

export interface JobRecord {
  id: string;
  kind: string;
  flavour: string | null;
  params: string | null;
  state: 'running' | 'completed' | 'failed' | string;
  started_at: string;
  finished_at: string | null;
  error: string | null;
  results: string | null;
  reload_needed: boolean;
  log_path: string | null;
}

export interface WtfSnapshot {
  id: string;
  addon_id: string;
  kind: string;
  path: string;
  file_count: number;
  total_bytes: number;
  created_at: string;
  restored_at: string | null;
}

export interface VersionItem {
  file_id: string;
  version: string;
  kind: string;
  date: string | null;
  is_current: boolean;
  is_pinned: boolean;
}

export interface ScannedCandidateGroup {
  name: string;
  source: string | null;
  project_id: number | null;
  wago_id: string | null;
  version: string | null;
  author: string | null;
  folders: string[];
}

export interface PatchCompatStatus {
  addon_id: string;
  name: string;
  installed_version: string | null;
  client_interface: number | null;
  toc_interface: number | null;
  is_old_patch: boolean;
}

export interface DiagnosticItem {
  name: string;
  ok: boolean;
  detail: string;
}

export interface MigrationBackup {
  name: string;
  path: string;
  size_bytes: number;
}

export interface AppState {
  addons: Addon[];
  flavours: Flavour[];
  active_flavour: string;
  freshness: Freshness;
  running_job: JobRecord | null;
  untracked_count: number;
  is_game_active: boolean;
  app_info: AppInfo;
}

export interface ThemeDef {
  slug: string;
  name: string;
  scheme: 'dark' | 'light';
  swBg: string;
  swBg2: string;
  swAccent: string;
  swText: string;
}

export interface AppUpdateInfo {
  status: string;
  current_version: string;
  update_version: string | null;
  release_notes: string | null;
  published_at: string | null;
  has_update: boolean;
  error?: string | null;
  download_url?: string | null;
  first_run_update?: string | null;
}

// Wago exposes no rating or trend data and rejects those sort values (DEC-FURPHY-010, amended 2026-11-03).
export type WagoSortOption = 'popular' | 'downloads' | 'updated' | 'name';

export interface WagoAddonItem {
  id: string;
  slug: string;
  name: string;
  description?: string;
  author: string;
  version?: string;
  downloads?: number;
  updated_at?: string;
  avatar_url?: string;
  wago_url?: string;
  game_version?: string;
  is_installed?: boolean;
}

export interface WagoSearchResponse {
  results: WagoAddonItem[];
  total: number;
  page: number;
  has_more: boolean;
}
