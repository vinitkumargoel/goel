import { useTranslation } from 'react-i18next'
import { PlayerDialog } from './components/detail/PlayerDialog'
import { PaletteHost } from './components/dialogs/CommandPalette'
import { ConfirmDialog } from './components/dialogs/ConfirmDialog'
import { ShortcutsDialog } from './components/dialogs/ShortcutsDialog'
import { HistoryView } from './components/history/HistoryView'
import { SettingsView } from './components/settings/SettingsView'
import { ReadOnlyBanner, ReconnectBanner } from './components/shell/Banners'
import { DrawerFooter } from './components/shell/DrawerFooter'
import { connectionOf, Header } from './components/shell/Header'
import { LibraryPane } from './components/shell/LibraryPane'
import { LibrarySheet } from './components/shell/LibrarySheet'
import { Rail } from './components/shell/Rail'
import { StatusBar } from './components/shell/StatusBar'
import { TabBar } from './components/shell/TabBar'
import { Toasts } from './components/shell/Toasts'
import { Menu } from './components/ui/Menu'
import { useAppController, type AppController } from './hooks/useAppController'
import { BOOT } from './lib/boot'

/**
 * The portal's one window. State, data and behaviour live in useAppController and the hooks it
 * wires together; the components here only lay the shell out.
 */
export function App() {
  const app = useAppController()
  return (
    <>
      <div className={`app${app.data.stale ? ' stale' : ''}`} inert={app.modalOpen}>
        <AppHeader app={app} />
        <div className="app-body">
          <AppRail app={app} />
          <main className="main" id="main">
            <MainView app={app} />
          </main>
          {app.state.view === 'library' && <AppSheet app={app} />}
        </div>
        <AppFooter app={app} />
      </div>
      <AppOverlays app={app} />
    </>
  )
}

interface Props {
  app: AppController
}

function AppHeader({ app }: Props) {
  const { data, model, nav, menus, state } = app
  return (
    <>
      <Header
        connection={connectionOf(data.live, data.loaded)}
        downSpeed={model.totals.down}
        upSpeed={model.totals.up}
        showPanelToggle={state.view === 'library' && !app.phone}
        panelOpen={model.panelShown}
        onTogglePanel={nav.togglePanel}
        onUserMenu={menus.openUserMenu}
        userMenuOpen={state.menu?.owner === 'user'}
      />

      <div className="banners">
        <ReconnectBanner stale={data.stale} lastUpdate={data.lastUpdate} now={data.now} onRetry={data.reconnect} />
        {BOOT.readOnly && <ReadOnlyBanner />}
      </div>
    </>
  )
}

function AppRail({ app }: Props) {
  const { state, model, nav, data, menus, canWrite } = app
  const { bandwidth, actions } = data
  // On a phone the status bar's controls move into the filter drawer.
  const drawerFooter =
    app.phone && (!BOOT.readOnly || bandwidth.state) ? (
      <DrawerFooter
        readOnly={BOOT.readOnly}
        canWrite={canWrite}
        bandwidth={bandwidth}
        bandwidthMenuOpen={state.menu?.owner === 'bandwidth'}
        onBandwidthMenu={menus.openBandwidthMenu}
        onPauseAll={actions.pauseAll}
        onResumeAll={actions.resumeAll}
      />
    ) : null
  return (
    <Rail
      variant={app.phone ? 'drawer' : 'rail'}
      view={state.view}
      filter={state.filter}
      counts={model.counts}
      tags={model.tagCounts}
      activeTag={state.tag}
      canWrite={canWrite}
      onSelectFilter={nav.goToFilter}
      onSelectView={nav.selectView}
      onSelectTag={nav.goToTag}
      onAdd={app.add.openAdd}
      // Labels need room: at tablet width the rail stays slim whatever was pinned.
      expanded={state.railExpanded && !app.narrow}
      onToggleExpanded={state.toggleRail}
      open={state.sidebarOpen}
      onClose={() => state.setSidebarOpen(false)}
      returnFocusTo={app.drawerButtonRef}
      footer={drawerFooter}
    />
  )
}

function MainView({ app }: Props) {
  const { t } = useTranslation()
  const { state, data, model, nav, menus, add, canWrite } = app
  const { toast, actions } = data
  if (state.view === 'history') {
    return (
      <HistoryView
        canWrite={canWrite}
        onReadd={add.readd}
        onRemoved={() => toast(t('toast.entryRemoved'), 'trash')}
        onWarn={data.warn}
        onToast={toast}
        refreshKey={model.finishedKey}
      />
    )
  }
  if (state.view === 'settings') {
    return (
      <SettingsView
        theme={app.theme}
        onTheme={app.setTheme}
        canWrite={canWrite}
        onToast={toast}
        bandwidth={data.bandwidth}
        onDirtyChange={app.settings.setSettingsDirty}
        panelAutoHide={state.panelAutoHide}
        onPanelAutoHide={state.setPanelAutoHide}
      />
    )
  }
  return (
    <LibraryPane
      state={state}
      model={model}
      wf={app.wf}
      tasks={data.tasks}
      loaded={data.loaded}
      error={data.error}
      canWrite={canWrite}
      readOnly={BOOT.readOnly}
      searchRef={app.searchRef}
      openAdd={add.openAdd}
      openAddWith={add.openAddWith}
      quickAdd={add.quickAdd}
      goToFilter={nav.goToFilter}
      goToTag={nav.goToTag}
      openMenu={menus.openMenu}
      openDetail={nav.openDetail}
      onSort={nav.onSort}
      onRowAction={app.onRowAction}
      openRowMenu={menus.openRowMenu}
      clearSearch={nav.clearSearch}
      refresh={data.refresh}
      openPlayer={app.openPlayer}
      runBulk={actions.runBulk}
      removeMany={actions.removeMany}
      copy={data.copy}
    />
  )
}

function AppSheet({ app }: Props) {
  const { state, data, model, nav, menus, detail, canWrite } = app
  return (
    <LibrarySheet
      model={model}
      tasks={data.tasks}
      loaded={data.loaded}
      error={data.error}
      bandwidth={data.bandwidth}
      autoHide={state.panelAutoHide}
      onAutoHide={state.setPanelAutoHide}
      onFilter={nav.goToFilter}
      detail={detail.detail}
      tab={state.tab}
      canWrite={canWrite}
      onTab={state.setTab}
      onClose={nav.closePanel}
      onAction={app.onRowAction}
      onRemove={(id, at) => menus.openMenu({ x: at.x, y: at.y, above: true, entries: menus.removeEntries(id) })}
      onMore={(id, at) => menus.openRowMenu(id, at.x, at.y, true)}
      onCopy={data.copy}
      onSetFiles={detail.setFilePriorities}
      onCyclePriority={detail.cyclePriority}
      queue={canWrite ? app.queue.controls : undefined}
      onStream={app.openPlayer}
      trapFocus={!app.modalOpen}
    />
  )
}

function AppFooter({ app }: Props) {
  const { state, data, model, nav, menus, canWrite } = app
  const { bandwidth, actions } = data
  if (app.phone) {
    return (
      <TabBar
        view={state.view}
        canWrite={canWrite}
        drawerOpen={state.sidebarOpen}
        onView={nav.selectView}
        onAdd={app.add.openAdd}
        onDrawer={() => state.setSidebarOpen((open) => !open)}
        drawerButtonRef={app.drawerButtonRef}
      />
    )
  }
  return (
    <StatusBar
      queue={model.counts}
      downSpeed={model.totals.down}
      upSpeed={model.totals.up}
      estimate={model.estimate}
      readOnly={BOOT.readOnly}
      onFilter={nav.goToFilter}
      onPauseAll={actions.pauseAll}
      onResumeAll={actions.resumeAll}
      bandwidth={bandwidth.status === 'unsupported' ? null : bandwidth.state}
      bandwidthMenuOpen={state.menu?.owner === 'bandwidth'}
      onBandwidthMenu={menus.openBandwidthMenu}
    />
  )
}

/** Dialogs, the menu and toasts: outside the inert window so they stay reachable. */
function AppOverlays({ app }: Props) {
  const { state, data, wf, nav, add, canWrite } = app
  const { tasks, actions, toasts } = data
  return (
    <>
      {add.dialog}

      {state.helpOpen && <ShortcutsDialog onClose={() => state.setHelpOpen(false)} />}
      {wf.paletteOpen && (
        <PaletteHost
          onClose={wf.closePalette}
          tasks={tasks}
          canWrite={canWrite}
          openAdd={add.openAdd}
          showTask={nav.showTask}
          goToFilter={nav.goToFilter}
          goToView={nav.selectView}
          togglePanel={nav.togglePanel}
          openHelp={() => state.setHelpOpen(true)}
          pauseAll={actions.pauseAll}
          resumeAll={actions.resumeAll}
          retryFailed={() =>
            void actions.runBulk(
              'retry',
              tasks.filter((task) => task.statusToken === 'failed').map((task) => task.id),
            )
          }
          setTheme={app.setTheme}
          setGroup={wf.setGroup}
          setDensity={wf.setDensity}
          setLayout={wf.setLayout}
        />
      )}
      {app.queue.dialog}
      {app.playingTask && (
        <PlayerDialog task={app.playingTask} onClose={() => state.setPlaying(null)} onCopy={data.copy} />
      )}

      <ConfirmDialog request={state.confirmReq} onClose={() => state.setConfirmReq(null)} />
      <Menu menu={state.menu} onClose={() => state.setMenu(null)} />
      <Toasts
        toasts={toasts.toasts}
        onDismiss={toasts.dismiss}
        onPause={toasts.pause}
        onResume={toasts.resume}
        onAction={toasts.act}
      />
    </>
  )
}
