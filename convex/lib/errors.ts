import { ConvexError } from 'convex/values';

export function unauthenticatedError(): ConvexError<{
  code: 'UNAUTHENTICATED';
  message: string;
}> {
  return new ConvexError({
    code: 'UNAUTHENTICATED',
    message: 'Unauthenticated',
  });
}
