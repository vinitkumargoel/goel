import { memo, useCallback, type ComponentProps, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtEta, fmtShortWhen, fmtSize, fmtSpeed, pct } from '../../lib/format'
import type { CardStyle } from '../../lib/lanes'
import { canSave, saveToDevice, saveURL } from '../../lib/saveFile'
import { sourceHost } from '../../lib/search'
import { fileType, kindBadge, kindLabel, rowAction } from '../../lib/taskKind'
import { isFaded, meterClass, meterFraction, stateTone } from '../../lib/tone'
import type { TaskRow } from '../../lib/types'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'
import { Bar, Ring } from '../ui/Meter'
import { ACTION_ICON, ItemButton, MoreButton, SelectTick, failureOf, optionProps, statusLabel, type ItemProps } from './itemShared'

type MeterTone = ComponentProps<typeof Ring>['tone']

interface BoardCardProps extends ItemProps {
  style: CardStyle
}

/**
 * One download on the board. While bytes move it is the tall card — artwork band, arc, rates;
 * every other state is the compact card, which says the one thing that state is about: its place
 * in the queue, the reason it failed, how far it got, when it finished.
 */
export const BoardCard = memo(function BoardCard(props: BoardCardProps) {
  const { task, selected, style, itemRef } = props
  const { t } = useTranslation()
  const id = task.id
  // Stable, or React detaches and re-attaches the ref on every render.
  const ref = useCallback((el: HTMLDivElement | null) => itemRef(id, el), [itemRef, id])
  const large = style === 'large'
  const cls = [
    'bcard',
    large ? 'dcard' : 'mcard',
    selected ? 'sel' : '',
    !large && task.statusToken === 'failed' ? 'fail' : '',
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <div ref={ref} className={cls} {...optionProps(props, t)}>
      {large ? <LargeBody {...props} /> : <CompactBody {...props} />}
      {props.selecting && <SelectTick on={selected} className="bc-check" />}
      {!props.phone && (
        <span className="bc-tools">
          <MoreButton task={task} onMenu={props.onMenu} className="ibtn sm" />
        </span>
      )}
    </div>
  )
})

/** The rate figures: ↓ in the accent, ↑ in the upload hue, the time left at the end. */
function Rates({ task, children }: { task: TaskRow; children?: ReactNode }) {
  const { t } = useTranslation()
  const eta = fmtEta(task.etaSeconds)
  return (
    <div className="stats">
      {task.statusToken === 'verifying' ? (
        <span>{statusLabel(task, t)}</span>
      ) : (
        <span className="acc">↓ {fmtSpeed(task.downSpeed)}</span>
      )}
      {task.upSpeed > 0 && <span className="upc">↑ {fmtSpeed(task.upSpeed)}</span>}
      <span className="sp" />
      {eta && <span>{t('library.left', { eta })}</span>}
      {children}
    </div>
  )
}

function ActionButton({ task, canWrite, phone, onAction, className }: ItemProps & { className: string }) {
  const { t } = useTranslation()
  const action = rowAction(task.statusToken)
  if (!action || !canWrite) return null
  return (
    <ItemButton
      label={t(`common.${action}`)}
      name={task.name}
      phone={phone}
      busy={task.busy}
      className={className}
      onPress={() => onAction(task.id, action)}
    >
      <Icon name={ACTION_ICON[action]} size="s" />
    </ItemButton>
  )
}

function LargeBody(props: BoardCardProps) {
  const { task } = props
  const { t } = useTranslation()
  const tone = meterClass(stateTone(task))
  // No total yet: the arc spins rather than claim a percentage.
  const value = task.totalBytes == null && task.statusToken === 'downloading' ? null : meterFraction(task)
  const where = sourceHost(task.source) || kindLabel(task.kind)
  return (
    <>
      <Art kind={fileType(task)} size="band">
        <span className="badge glass" title={kindLabel(task.kind)}>
          {kindBadge(task.kind)}
        </span>
      </Art>
      <div className="db">
        <span className="nm">{task.name}</span>
        <Ring value={value} size={46} tone={tone as MeterTone} sweep label={t('library.progress')}>
          {value != null && <b>{Math.round(pct(value))}</b>}
        </Ring>
        <span className="mt">
          {where} · {fmtSize(task.totalBytes)}
        </span>
        <Rates task={task}>
          <ActionButton {...props} className="ibtn sm bc-act" />
        </Rates>
      </div>
    </>
  )
}

function CompactBody(props: BoardCardProps) {
  const { task, now } = props
  const { t } = useTranslation()
  const whole = Math.round(pct(task.progress))
  const size = fmtSize(task.totalBytes)
  const badge = kindBadge(task.kind)
  const failure = failureOf(task)
  let line: ReactNode = null
  let meter: ReactNode = null
  let trailing: ReactNode = null

  switch (task.statusToken) {
    case 'queued': {
      const parts = [badge, size, statusLabel(task, t)]
      if (task.queuePosition != null) parts.push(`#${task.queuePosition + 1}`)
      if (task.startAt) parts.push(t('board.card.startsAt', { when: fmtShortWhen(task.startAt, now) }))
      line = <span className="mt">{parts.join(' · ')}</span>
      break
    }
    case 'metadata':
      line = <span className="mt">{t('board.card.requesting')}</span>
      meter = <Bar value={null} thin label={t('library.progress')} />
      trailing = <ActionButton {...props} className="ibtn sm b bc-act" />
      break
    case 'downloading':
    case 'verifying': {
      const eta = fmtEta(task.etaSeconds)
      const parts = [`${whole}%`, task.downSpeed > 0 ? `↓ ${fmtSpeed(task.downSpeed)}` : null, eta]
      meter = <Bar value={meterFraction(task)} thin label={t('library.progress')} />
      line = <span className="mt mono">{parts.filter(Boolean).join(' · ')}</span>
      trailing = <ActionButton {...props} className="ibtn sm b bc-act" />
      break
    }
    case 'failed':
      line = (
        <>
          <span className="why" title={failure ?? undefined}>
            {failure ?? statusLabel(task, t)}
          </span>
          {props.canWrite && (
            <span className="bc-row">
              <ItemButton
                label={t('common.retry')}
                name={task.name}
                phone={props.phone}
                busy={task.busy}
                className="btn sm soft"
                onPress={() => props.onAction(task.id, 'retry')}
              >
                <Icon name="retry" />
                {t('common.retry')}
              </ItemButton>
            </span>
          )}
        </>
      )
      break
    case 'paused':
      line = <span className="mt">{[statusLabel(task, t), `${whole}%`, size].join(' · ')}</span>
      meter = <Bar value={task.progress} thin tone="paused" label={t('library.progress')} />
      trailing = <ActionButton {...props} className="ibtn sm b bc-act" />
      break
    case 'seeding': {
      const parts = [t('board.card.seeding', { ratio: task.ratio.toFixed(2) })]
      if (task.upSpeed > 0) parts.push(`↑ ${fmtSpeed(task.upSpeed)}`)
      line = <span className="mt upc">{parts.join(' · ')}</span>
      meter = <Bar value={meterFraction(task)} thin tone="up" label={t('library.progress')} />
      break
    }
    case 'completed': {
      const parts = [badge, size]
      if (task.completedAt) parts.push(fmtShortWhen(task.completedAt, now))
      line = <span className="mt">{parts.join(' · ')}</span>
      trailing = <FinishedButton {...props} />
      break
    }
  }

  return (
    <>
      {task.statusToken === 'queued' && task.queuePosition != null && (
        <span className="lnum" aria-hidden="true">
          #{task.queuePosition + 1}
        </span>
      )}
      <Art kind={fileType(task)} size="s" faded={isFaded(task)} />
      <div className="tx">
        <span className="nm">{task.name}</span>
        {line}
        {meter}
      </div>
      {trailing}
    </>
  )
}

/** A finished file: play it here when the browser can, else save it to this device. */
function FinishedButton({ task, phone, onStream }: ItemProps) {
  const { t } = useTranslation()
  if (task.streamable && onStream) {
    return (
      <ItemButton
        label={t('common.stream')}
        name={task.name}
        phone={phone}
        className="ibtn sm b bc-act"
        onPress={() => onStream(task)}
      >
        <Icon name="play" size="s" />
      </ItemButton>
    )
  }
  if (!canSave(task)) return null
  return (
    <ItemButton
      label={t('menu.saveToDevice')}
      name={task.name}
      phone={phone}
      className="ibtn sm b bc-act"
      onPress={() => saveToDevice(saveURL(task), task.multiFile ? '' : task.name)}
    >
      <Icon name="download" size="s" />
    </ItemButton>
  )
}
