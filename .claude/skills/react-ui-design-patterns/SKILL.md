---
name: react-ui-design-patterns
description:
  Professional React UI patterns for async states, loading skeletons, optimistic
  updates, empty states, error boundaries, and data fetching. Use when building
  screens that load data, handle errors, show empty states, or need optimistic
  mutations. Aligned with Fluent UI React v9 and React Query.
metadata:
  source: mcpmarket.com/tools/skills/react-ui-design-patterns-1
  stack: React 18, @fluentui/react-components, @tanstack/react-query
  version: '1.0.0'
---

# React UI Design Patterns

Professional patterns for production-quality React UIs. Covers all states a
data-driven screen can be in: loading, error, empty, populated, and optimistic.

## When to Activate

- Building a screen that fetches data from an API
- "Add a loading state / skeleton"
- "Handle errors gracefully"
- "Show an empty state when there's no data"
- "Optimistic update on mutation"
- "Add an error boundary"
- Reviewing a component for missing states

## The Five States Rule

Every data-driven screen MUST handle all five states:

| State | Trigger | Fluent UI Pattern |
|---|---|---|
| **Loading** | `isLoading === true` | `Skeleton` components matching layout |
| **Error** | `isError === true` | `MessageBar` with `intent="error"` + retry |
| **Empty** | data is `[]` or `null` | Empty state illustration + CTA |
| **Populated** | data has items | Normal render |
| **Optimistic** | mutation pending | Disabled UI + local state update |

## Loading Skeletons (Fluent v9)

Match the skeleton shape to the final rendered layout:

```tsx
import { Skeleton, SkeletonItem } from '@fluentui/react-components';

function UserCardSkeleton() {
  return (
    <Skeleton>
      <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
        <SkeletonItem shape="circle" size={40} />
        <div style={{ flex: 1 }}>
          <SkeletonItem style={{ width: '60%', marginBottom: 6 }} />
          <SkeletonItem style={{ width: '40%' }} />
        </div>
      </div>
    </Skeleton>
  );
}

// Use in component
if (isLoading) return <UserCardSkeleton />;
```

## Error States (Fluent v9)

```tsx
import { MessageBar, MessageBarBody, MessageBarActions, Button } from '@fluentui/react-components';

function ErrorState({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <MessageBar intent="error">
      <MessageBarBody>{message ?? 'Something went wrong. Please try again.'}</MessageBarBody>
      <MessageBarActions>
        <Button onClick={onRetry}>Retry</Button>
      </MessageBarActions>
    </MessageBar>
  );
}

// Use in component
if (isError) return <ErrorState message={error.message} onRetry={refetch} />;
```

## Empty States

```tsx
function EmptyState({ title, description, action }: {
  title: string;
  description: string;
  action?: React.ReactNode;
}) {
  return (
    <div style={{ textAlign: 'center', padding: '48px 24px' }}>
      <Text size={500} weight="semibold" block>{title}</Text>
      <Text size={300} style={{ color: 'var(--colorNeutralForeground2)' }} block>
        {description}
      </Text>
      {action && <div style={{ marginTop: 16 }}>{action}</div>}
    </div>
  );
}

// Use in component
if (!data || data.length === 0) {
  return (
    <EmptyState
      title="No assistants yet"
      description="Create your first assistant to get started."
      action={<Button appearance="primary" onClick={onCreate}>Create Assistant</Button>}
    />
  );
}
```

## Optimistic Updates (React Query)

```tsx
const queryClient = useQueryClient();

const deleteUser = useMutation({
  mutationFn: (userId: string) => api.delete(`/users/${userId}`),

  // 1. Snapshot + cancel in-flight queries
  onMutate: async (userId) => {
    await queryClient.cancelQueries({ queryKey: ['users'] });
    const snapshot = queryClient.getQueryData<User[]>(['users']);

    // 2. Optimistically remove from cache
    queryClient.setQueryData<User[]>(['users'], (old) =>
      old?.filter((u) => u.id !== userId) ?? []
    );

    return { snapshot };  // context for rollback
  },

  // 3. Rollback on error
  onError: (_err, _userId, context) => {
    if (context?.snapshot) {
      queryClient.setQueryData(['users'], context.snapshot);
    }
    toast.error('Failed to delete user');
  },

  // 4. Refetch after success/error
  onSettled: () => {
    queryClient.invalidateQueries({ queryKey: ['users'] });
  },
});
```

## Confirmation Dialogs (Fluent v9)

```tsx
import { Dialog, DialogTrigger, DialogSurface, DialogTitle,
         DialogBody, DialogActions, Button } from '@fluentui/react-components';

function DeleteConfirmDialog({ onConfirm, isLoading }: {
  onConfirm: () => void;
  isLoading: boolean;
}) {
  return (
    <Dialog>
      <DialogTrigger disableButtonEnhancement>
        <Button appearance="subtle" icon={<DeleteRegular />} aria-label="Delete" />
      </DialogTrigger>
      <DialogSurface>
        <DialogBody>
          <DialogTitle>Delete this item?</DialogTitle>
          <DialogActions>
            <DialogTrigger disableButtonEnhancement>
              <Button appearance="secondary">Cancel</Button>
            </DialogTrigger>
            <Button appearance="primary" onClick={onConfirm} disabled={isLoading}>
              {isLoading ? 'Deleting...' : 'Delete'}
            </Button>
          </DialogActions>
        </DialogBody>
      </DialogSurface>
    </Dialog>
  );
}
```

## React Error Boundary

```tsx
import { Component, type ReactNode } from 'react';
import { MessageBar, MessageBarBody, Button } from '@fluentui/react-components';

class ErrorBoundary extends Component<
  { children: ReactNode; fallback?: ReactNode },
  { hasError: boolean }
> {
  state = { hasError: false };

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  render() {
    if (this.state.hasError) {
      return this.props.fallback ?? (
        <MessageBar intent="error">
          <MessageBarBody>An unexpected error occurred.</MessageBarBody>
        </MessageBar>
      );
    }
    return this.props.children;
  }
}

// Wrap at route level
<ErrorBoundary>
  <SomePage />
</ErrorBoundary>
```

## Data Fetching Pattern (React Query + this project)

```tsx
function UserList() {
  const { data: users, isLoading, isError, error, refetch } = useUsers();

  if (isLoading) return <UserListSkeleton />;
  if (isError) return <ErrorState message={error.message} onRetry={refetch} />;
  if (!users?.length) return <EmptyState title="No users" description="Invite your first user." />;

  return (
    <DataGrid items={users} columns={columns} />
  );
}
```

## Pagination Pattern

```tsx
const [page, setPage] = useState(1);
const PAGE_SIZE = 20;

const { data } = useQuery({
  queryKey: ['users', { page, pageSize: PAGE_SIZE }],
  queryFn: () => api.get('/users', { page, pageSize: PAGE_SIZE }),
  placeholderData: keepPreviousData,  // no loading flash on page change
});
```
