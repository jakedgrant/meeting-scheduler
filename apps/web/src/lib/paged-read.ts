// F19 read contract: cursor pages with an explicit continuation and a
// database total on the first page. See docs/read-contracts.md.
export interface Page<T> {
  items: T[]
  has_more: boolean
  next_cursor: string | null
  total_count: number | null
}

/** A traversal or payload that cannot be shown as complete. */
export class IncompleteReadError extends Error {
  constructor(message = 'The server returned an incomplete result. Please retry.') {
    super(message)
    this.name = 'IncompleteReadError'
  }
}

export function checkedPage<T>(value: unknown): Page<T> {
  const page = value as Page<T>
  if (!page || !Array.isArray(page.items) || typeof page.has_more !== 'boolean'
      || page.has_more !== (typeof page.next_cursor === 'string')
      || (page.total_count !== null && !Number.isSafeInteger(page.total_count))) {
    throw new IncompleteReadError()
  }
  return page
}

/**
 * Follows cursors until the server reports no continuation. The collected rows
 * must be distinct and match the first page's total; a concurrent change makes
 * the traversal fail rather than display a silently partial or mixed result.
 */
export async function readAllPages<T>(
  fetchPage: (cursor: string | null) => Promise<Page<T>>,
  key: (item: T) => string,
  maxPages = 100
): Promise<T[]> {
  const rows: T[] = []
  const seen = new Set<string>()
  let cursor: string | null = null
  let total: number | null = null
  for (let pages = 0; ; pages++) {
    if (pages >= maxPages) throw new IncompleteReadError()
    const page: Page<T> = checkedPage<T>(await fetchPage(cursor))
    if (pages === 0) total = page.total_count
    for (const item of page.items) {
      const id = key(item)
      if (seen.has(id)) throw new IncompleteReadError()
      seen.add(id)
      rows.push(item)
    }
    if (!page.has_more) break
    if (page.next_cursor === cursor) throw new IncompleteReadError()
    cursor = page.next_cursor
  }
  if (total === null || rows.length !== total) throw new IncompleteReadError()
  return rows
}
