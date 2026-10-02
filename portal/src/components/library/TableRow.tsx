import { memo, useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtAbsolute, fmtAgo, fmtEta, fmtProgressSize, fmtSize, fmtSpeed } from '../../lib/format'
import { fileType, kindBadge, kindLabel, rowAction } from '../../lib/taskKind'
import { isFaded, meterClass, meterFraction, pillClass, stateTone } from '../../lib/tone'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'
import { Bar } from '../ui/Meter'
import { ACTION_ICON, ItemButton, MoreButton, SelectTick, failureOf, optionProps, statusText, type ItemProps } from './itemShared'

type BarTone = '' | 'paused' | 'up' | 'good' | 'bad' | 'warn'

/**
 * One download as a table row: name (artwork, badge, a thin bar), size, a status pill, speed,
 * when it was added. On a phone it is a compact card instead — the columns fold into a meta line.
 */
export const TableRow = memo(function TableRow(props: ItemProps) {
  const { task, selected, canWrite, phone, selecting, now, itemRef, onAction } = props
  const { t } = useTranslation()
  const id = task.id
  const ref = useCallback((el: HTMLDivElement | null) => itemRef(id, el), [itemRef, id])
  const action = rowAction(task.statusToken)
  const failure = failureOf(task)
  const tone = stateTone(task)
  const status = statusText(task, t)
  const speed = task.downSpeed > 0 ? fmtSpeed(task.downSpeed) : null
  const value = task.statusToken === 'metadata' ? null : meterFraction(task)
  const actionLabel = action ? t(`common.${action}`) : ''
  const actionButton = (className: string) =>
    action && canWrite ? (
      <ItemButton
        label={actionLabel}
        name={task.name}
        phone={phone}
        className={className}
        onPress={() => onAction(task.id, action)}
      >
        <Icon name={ACTION_ICON[action]} size="s" />
      </ItemButton>
    ) : null

  const nameLine = (
    <span className="lt-nline">
      <b className="lt-nm">{task.name}</b>
      <span className="badge" title={kindLabel(task.kind)}>
        {kindBadge(task.kind)}
      </span>
    </span>
  )
  const bar = <Bar value={value} thin tone={meterClass(tone) as BarTone} label={t('library.progress')} />

  if (phone) {
    const meta = [
      task.statusToken === 'downloading' ? fmtProgressSize(task.doneBytes, task.totalBytes) : status,
      speed,
      fmtEta(task.etaSeconds),
    ]
    return (
      <div ref={ref} className={`lt-row lt-phone${selected ? ' sel' : ''}`} {...optionProps(props, t)}>
        {selecting && <SelectTick on={selected} className="lt-check" />}
        <Art kind={fileType(task)} size="s" faded={isFaded(task)} />
        <span className="lt-t">
          {nameLine}
          {bar}
          <span className={`lt-pmeta${failure ? ' badc' : ''}`}>
            {failure ? `${task.status} — ${failure}` : meta.filter(Boolean).join(' · ')}
          </span>
        </span>
        {actionButton('ibtn b lt-pbtn')}
      </div>
    )
  }

  return (
    <div ref={ref} className={`lt-row${selected ? ' sel' : ''}`} {...optionProps(props, t)}>
      <span className="lt-c lt-name">
        {selecting && <SelectTick on={selected} className="lt-check" />}
        <span className="lt-art">
          <Art kind={fileType(task)} size="s" faded={isFaded(task)} />
          {actionButton('lt-act')}
        </span>
        <span className="lt-t">
          {nameLine}
          {failure ? (
            <span className="lt-why badc" title={failure}>
              {failure}
            </span>
          ) : (
            bar
          )}
          {/* Shown once the Status or Speed column is gone, so neither is ever lost. */}
          <span className="lt-nstat">
            <span className="lt-ns-status">{status}</span>
            {speed && <span className="lt-ns-speed acc">↓ {speed}</span>}
          </span>
        </span>
      </span>
      <span className="lt-c lt-size mono">{fmtSize(task.totalBytes)}</span>
      <span className="lt-c lt-status">
        <span className={pillClass(tone)} title={failure ?? undefined}>
          {status}
        </span>
      </span>
      {/* Idle rows show nothing, as the native list does; upload gets a second line. */}
      <span className="lt-c lt-speed mono">
        {speed && <span className="acc">↓ {speed}</span>}
        {task.upSpeed > 0 && <span className="lt-up upc">↑ {fmtSpeed(task.upSpeed)}</span>}
      </span>
      <span className="lt-c lt-added" title={task.addedAt ? fmtAbsolute(task.addedAt) : undefined}>
        {task.addedAt ? fmtAgo(task.addedAt, now) : '—'}
      </span>
      <span className="lt-c lt-more">
        <MoreButton task={task} onMenu={props.onMenu} className="ibtn sm" />
      </span>
    </div>
  )
})
