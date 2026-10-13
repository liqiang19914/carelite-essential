import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import UsersPage from "@/pages/platform/UsersPage";
import UserProfilePage from "@/pages/platform/UserProfilePage";
import ClientsPage from "@/pages/merchant/ClientsPage";
import AssistantPage from "@/pages/merchant/AssistantPage";
import SettingsPage from "@/pages/settings/SettingsPage";

const queryClient = new QueryClient();

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <Routes>
          <Route path="/platform/users" element={<UsersPage />} />
          <Route path="/platform/users/:id" element={<UserProfilePage />} />
          <Route path="/merchant/clients" element={<ClientsPage />} />
          <Route path="/merchant/clients/:id" element={<UserProfilePage />} />
          <Route path="/merchant/assistant" element={<AssistantPage />} />
          <Route path="/settings" element={<SettingsPage />} />
          <Route path="*" element={<Navigate to="/merchant/assistant" replace />} />
        </Routes>
      </BrowserRouter>
    </QueryClientProvider>
  );
}
