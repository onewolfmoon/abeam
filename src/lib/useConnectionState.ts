import { useEffect, useState } from "react";
import type { ConnectionState, ReceiverConnection } from "./receiverConnection";

export function useConnectionState(connection: ReceiverConnection): ConnectionState {
  const [state, setState] = useState(connection.state);
  useEffect(() => connection.subscribe(setState), [connection]);
  return state;
}
