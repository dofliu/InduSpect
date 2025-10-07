import React, { useState, useCallback, useId } from 'react';
import ReactDOM from 'react-dom/client';
import { GoogleGenAI, Type } from "@google/genai";

// --- Type Definitions ---
interface AnalysisResult {
    equipment_type: string;
    readings: {
        label: string;
        value: number | null;
        unit: string | null;
    }[];
    condition_assessment: string;
    is_anomaly: boolean;
    summary: string;
}

type ChecklistItemStatus = 'pending' | 'capturing' | 'captured' | 'loading' | 'success' | 'error' | 'confirmed';

interface ChecklistItem {
    id: string;
    task: string;
    file: File | null;
    imageUrl: string | null;
    status: ChecklistItemStatus;
    result: AnalysisResult | null;
    error: string | null;
}

type AppState = 'IDLE' | 'EXTRACTING' | 'CAPTURE' | 'ANALYZING' | 'REVIEW';

// --- Helper Functions ---
const fileToGenerativePart = async (file: File) => {
    const base64EncodedDataPromise = new Promise<string>((resolve) => {
        const reader = new FileReader();
        reader.onloadend = () => resolve((reader.result as string).split(',')[1]);
        reader.readAsDataURL(file);
    });
    return {
        inlineData: { data: await base64EncodedDataPromise, mimeType: file.type },
    };
};

// --- Child Components ---

const Stepper = ({ appState }: { appState: AppState }) => {
    const steps = [
        { id: 'IDLE', label: '上傳定檢表' },
        { id: 'CAPTURE', label: '拍攝巡檢照片' },
        { id: 'REVIEW', label: '分析與審核' },
    ];

    const getStateClassName = (stepId: string): string => {
        if (stepId === 'IDLE' && (appState === 'IDLE' || appState === 'EXTRACTING')) return 'step active';
        if (stepId === 'CAPTURE' && appState === 'CAPTURE') return 'step active';
        if (stepId === 'REVIEW' && (appState === 'REVIEW' || appState === 'ANALYZING')) return 'step active';

        if (steps.findIndex(s => s.id === appState) > steps.findIndex(s => s.id === stepId)) {
             return 'step completed';
        }
       
        return 'step';
    }

    return (
        <div className="stepper" aria-label="進度">
            {steps.map(step => (
                <div key={step.id} className={getStateClassName(step.id)}>
                    {step.label}
                </div>
            ))}
        </div>
    );
};

const LoadingComponent = ({ text }: { text: string }) => (
    <div className="loading-container" role="status">
        <div className="loader"></div>
        <p>{text}</p>
    </div>
);

const InspectionCard: React.FC<{
    item: ChecklistItem,
    onConfirm: (id: string) => void,
    onRetry: (id: string, event: React.ChangeEvent<HTMLInputElement>) => void,
}> = ({ item, onConfirm, onRetry }) => {
    const renderResult = (result: AnalysisResult) => (
        <div className="results-container">
            <div className="result-item">
                <strong>設備類型：</strong>
                <span>{result.equipment_type}</span>
            </div>
            <div className="result-item">
                <strong>儀表讀數：</strong>
                {result.readings && result.readings.length > 0 ? (
                    <div className="readings-grid">
                        {result.readings.map((reading, index) => (
                            <div key={index} className="reading">
                                <span className="reading-label">{reading.label}:</span>
                                <span className="reading-value">
                                    {reading.value !== null && reading.value !== undefined ? `${reading.value} ${reading.unit || ''}`.trim() : 'N/A'}
                                </span>
                            </div>
                        ))}
                    </div>
                ) : (
                    <span>無</span>
                )}
            </div>
            <div className="result-item">
                <strong>狀況評估：</strong>
                <p>{result.condition_assessment}</p>
            </div>
            <div className="result-item">
                <strong>偵測到異常：</strong>
                <span className={result.is_anomaly ? 'anomaly' : 'no-anomaly'}>
                    {result.is_anomaly ? '是' : '否'}
                </span>
            </div>
             <div className="result-item summary">
                <strong>AI 總結：</strong>
                <p>{result.summary}</p>
            </div>
        </div>
    );
    
    return (
        <div className={`inspection-card ${item.status === 'confirmed' ? 'confirmed' : ''}`} role="listitem">
           <h3 className="card-header">{item.task}</h3>
           <div className="card-content">
                <div className="image-container">
                    {item.imageUrl && <img src={item.imageUrl} alt={`預覽 ${item.task}`} />}
                    {item.status === 'loading' && <div className="loader" role="status" aria-label="分析加載中"></div>}
                </div>
                <div style={{flex: '1 1 60%'}}>
                    {item.status === 'success' && item.result && renderResult(item.result)}
                    {item.status === 'confirmed' && item.result && renderResult(item.result)}
                    {item.status === 'error' && <div className="error-message" role="alert">{item.error}</div>}
                </div>
           </div>
            <div className="card-actions">
                {item.status === 'error' && (
                    <>
                        <input
                            type="file"
                            id={`retry-upload-${item.id}`}
                            accept="image/*"
                            capture="environment"
                            onChange={(e) => onRetry(item.id, e)}
                            style={{ display: 'none' }}
                        />
                        <label htmlFor={`retry-upload-${item.id}`} className="button-retry">
                            重新拍攝並分析
                        </label>
                    </>
                )}
                <button onClick={() => onConfirm(item.id)} disabled={item.status !== 'success'}>
                    {item.status === 'confirmed' ? '已記錄' : '確認記錄'}
                </button>
            </div>
        </div>
    );
};

const RecordsTable = ({ records }: { records: ChecklistItem[] }) => {
    if (records.length === 0) return null;
    return (
        <section className="records-section" aria-labelledby="records-heading">
            <h2 id="records-heading">檢測記錄</h2>
            <div className="records-table-container">
                <table className="records-table">
                    <thead>
                        <tr>
                            <th>#</th>
                            <th>檢測項目</th>
                            <th>照片</th>
                            <th>設備類型</th>
                            <th>儀表讀數</th>
                            <th>AI 總結</th>
                            <th>異常?</th>
                        </tr>
                    </thead>
                    <tbody>
                        {records.map((record, index) => (
                            <tr key={record.id}>
                                <td>{index + 1}</td>
                                <td>{record.task}</td>
                                <td>{record.imageUrl && <img src={record.imageUrl} alt={record.task} />}</td>
                                <td>{record.result?.equipment_type}</td>
                                <td>
                                    {record.result?.readings.map(r => `${r.label}: ${r.value ?? 'N/A'} ${r.unit ?? ''}`).join(', ') || 'N/A'}
                                </td>
                                <td>{record.result?.summary}</td>
                                <td>
                                    <span className={record.result?.is_anomaly ? 'anomaly' : 'no-anomaly'}>
                                        {record.result?.is_anomaly ? '是' : '否'}
                                    </span>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </section>
    );
};

// --- Main App Component ---

const App = () => {
    const [appState, setAppState] = useState<AppState>('IDLE');
    const [checklist, setChecklist] = useState<ChecklistItem[]>([]);
    const [confirmedRecords, setConfirmedRecords] = useState<ChecklistItem[]>([]);
    const [error, setError] = useState<string | null>(null);
    const uniqueId = useId();

    const handleFormUpload = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        setAppState('EXTRACTING');
        setError(null);

        try {
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
            const imagePart = await fileToGenerativePart(file);

            const prompt = `您是一位文件分析專家。請仔細閱讀提供的巡檢表單圖片，並提取出所有需要執行的巡檢項目。
            
            任務指令：
            1. 識別並列出表單中的每一個獨立的檢查任務或項目。
            2. 忽略標題、日期、簽名欄位等非任務相關的文字。
            
            輸出格式：
            請務必以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。所有回傳的文字都必須使用繁體中文。JSON 結構必須是一個包含字串陣列的物件，如下：
            { "tasks": ["項目一", "項目二", "項目三"] }`;

            const responseSchema = {
                type: Type.OBJECT,
                properties: {
                    tasks: {
                        type: Type.ARRAY,
                        items: { type: Type.STRING }
                    }
                },
                required: ["tasks"]
            };
            
            const response = await ai.models.generateContent({
                model: 'gemini-2.5-flash',
                contents: { parts: [imagePart, { text: prompt }] },
                config: {
                    responseMimeType: "application/json",
                    responseSchema: responseSchema,
                },
            });
            
            const resultJson = JSON.parse(response.text);
            const newChecklist: ChecklistItem[] = resultJson.tasks.map((task: string, index: number) => ({
                id: `${uniqueId}-${Date.now()}-${index}`,
                task,
                file: null,
                imageUrl: null,
                status: 'pending',
                result: null,
                error: null,
            }));

            if(newChecklist.length === 0) {
                throw new Error("無法從文件中提取任何檢查項目。");
            }

            setChecklist(newChecklist);
            setAppState('CAPTURE');

        } catch (e: any) {
            console.error(e);
            setError(`無法分析定檢表: ${e.message}`);
            setAppState('IDLE');
        } finally {
             event.target.value = '';
        }
    }, [uniqueId]);

    const handlePhotoCapture = (itemId: string, event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        setChecklist(prev => prev.map(item => 
            item.id === itemId ? { ...item, file, imageUrl: URL.createObjectURL(file), status: 'captured' } : item
        ));
        event.target.value = '';
    };

    const runAnalysisOnItem = useCallback(async (itemToAnalyze: ChecklistItem) => {
        if (!itemToAnalyze.file) return;
        try {
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
            const imagePart = await fileToGenerativePart(itemToAnalyze.file!);

            const prompt = `您是一位專業且謹慎的工業巡檢 AI。您的任務分為兩階段：首先驗證圖像，然後才進行詳細分析。

巡檢任務： "${itemToAnalyze.task}"

第一階段：圖像驗證
在進行任何分析之前，請先回答以下兩個問題：
1.  **相關性檢查**：圖像中的主要物體是否與上述的「巡檢任務」相符？（例如：如果任務是「檢查壓力錶」，圖像中必須要有壓力錶）。
2.  **品質檢查**：圖像是否清晰、光線充足且沒有嚴重模糊，足以進行準確分析？

第二階段：條件式分析
- **如果驗證失敗**（圖像不相關或品質不佳）：請立即停止，並在 'validation_error' 欄位中用繁體中文清楚說明失敗的原因。不要填寫 'analysis' 物件。
- **如果驗證成功**：請繼續進行詳細分析，並填寫 'analysis' 物件中的所有欄位。

分析指令 (僅在驗證成功時執行)：
1.  識別圖像中的主要設備類型。
2.  如果存在任何儀表或計量器，請讀取其數值、標籤和單位。
3.  評估設備的整體狀況（如：生鏽、洩漏、損壞）。
4.  判斷是否存在異常。
5.  提供一個簡潔的總結或建議。

輸出格式：
請務必將您的所有發現以一個單一、最小化、不含 markdown 標記的 JSON 物件格式回傳。JSON 內所有字串的值 (value) 都必須使用繁體中文。JSON 結構必須如下：`;

            const responseSchema = {
                type: Type.OBJECT,
                properties: {
                    validation_passed: { type: Type.BOOLEAN },
                    validation_error: { type: Type.STRING, nullable: true },
                    analysis: {
                        type: Type.OBJECT,
                        nullable: true,
                        properties: {
                            equipment_type: { type: Type.STRING },
                            readings: { type: Type.ARRAY, items: { type: Type.OBJECT, properties: { label: { type: Type.STRING }, value: { type: Type.NUMBER, nullable: true }, unit: { type: Type.STRING, nullable: true } }, required: ["label", "value"] }},
                            condition_assessment: { type: Type.STRING },
                            is_anomaly: { type: Type.BOOLEAN },
                            summary: { type: Type.STRING }
                        },
                        required: ["equipment_type", "readings", "condition_assessment", "is_anomaly", "summary"]
                    }
                },
                required: ["validation_passed"]
            };

            const response = await ai.models.generateContent({
                model: 'gemini-2.5-flash',
                contents: { parts: [imagePart, { text: prompt }] },
                config: { responseMimeType: "application/json", responseSchema: responseSchema },
            });
            
            const resultJson = JSON.parse(response.text);
            
            if (resultJson.validation_passed && resultJson.analysis) {
                setChecklist(prev => prev.map(i => i.id === itemToAnalyze.id ? { ...i, status: 'success', result: resultJson.analysis } : i));
            } else {
                const errorMessage = resultJson.validation_error || "圖像驗證失敗，但未提供具體原因。";
                throw new Error(errorMessage);
            }

        } catch (e: any) {
            console.error(e);
            setChecklist(prev => prev.map(i => i.id === itemToAnalyze.id ? { ...i, status: 'error', error: `分析失敗: ${e.message}` } : i));
        }
    }, []);
    
    const startAnalysis = useCallback(async () => {
        setAppState('ANALYZING');
        const itemsToAnalyze = checklist.filter(item => item.status === 'captured' && item.file);
        
        const itemIdsToAnalyze = itemsToAnalyze.map(i => i.id);
        setChecklist(prev => prev.map(item => 
            itemIdsToAnalyze.includes(item.id) ? { ...item, status: 'loading' } : item
        ));
        
        const analysisPromises = itemsToAnalyze.map(item => runAnalysisOnItem(item));
        await Promise.all(analysisPromises);
        setAppState('REVIEW');
    }, [checklist, runAnalysisOnItem]);

    const handlePhotoRetry = (itemId: string, event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        const itemToUpdate = checklist.find(i => i.id === itemId);
        if (!itemToUpdate) return;
        
        const updatedItem = {
            ...itemToUpdate,
            file,
            imageUrl: URL.createObjectURL(file),
            status: 'loading' as ChecklistItemStatus,
            error: null,
            result: null,
        };

        setChecklist(prev => prev.map(i => i.id === itemId ? updatedItem : i));
        
        runAnalysisOnItem(updatedItem);
        event.target.value = '';
    };

    const handleConfirmOne = (id: string) => {
        const itemToConfirm = checklist.find(item => item.id === id);
        if (!itemToConfirm || itemToConfirm.status !== 'success') return;
        
        setChecklist(prev => prev.map(item => item.id === id ? { ...item, status: 'confirmed' } : item));
        setConfirmedRecords(prev => [...prev, itemToConfirm]);
    };
    
    const handleConfirmAll = () => {
        const itemsToConfirm = checklist.filter(item => item.status === 'success');
        if (itemsToConfirm.length === 0) return;
        
        const confirmedIds = itemsToConfirm.map(item => item.id);
        
        setChecklist(prev => prev.map(item => confirmedIds.includes(item.id) ? { ...item, status: 'confirmed' } : item));
        setConfirmedRecords(prev => [...prev, ...itemsToConfirm]);
    };

    const renderContent = () => {
        switch (appState) {
            case 'IDLE':
                return (
                    <section className="upload-section" aria-labelledby="upload-heading">
                        <h2 id="upload-heading">步驟 1: 上傳您的定檢表</h2>
                        <p>請上傳包含巡檢項目的文件圖片 (PNG, JPG)，AI 將自動為您提取檢查清單。</p>
                        <input type="file" id="form-upload" aria-label="上傳定檢表" accept="image/png, image/jpeg" onChange={handleFormUpload} />
                        <label htmlFor="form-upload" className="file-upload-label">選擇定檢表照片</label>
                        {error && <div className="error-message" style={{marginTop: '1rem'}} role="alert">{error}</div>}
                    </section>
                );
            case 'EXTRACTING':
                return <LoadingComponent text="正在從文件中提取巡檢項目..." />;
            case 'CAPTURE':
                const allPhotosTaken = checklist.every(item => item.status === 'captured');
                const activeItemIndex = checklist.findIndex(item => item.status === 'pending');
                const currentTask = activeItemIndex !== -1 ? checklist[activeItemIndex].task : "所有照片已拍攝完畢！";
                return (
                    <section className="capture-section">
                        <h3>步驟 2: 拍攝巡檢照片</h3>
                        <p>下一個項目：<strong>{currentTask}</strong></p>
                        <ul className="checklist">
                            {checklist.map((item, index) => (
                                <li key={item.id} className={`checklist-item ${index === activeItemIndex ? 'active' : ''} ${item.status === 'captured' ? 'completed' : ''}`}>
                                    <span className="checklist-item-text">{index + 1}. {item.task}</span>
                                    <div className="checklist-item-action">
                                        {item.imageUrl ? (
                                             <img src={item.imageUrl} alt={`預覽 ${item.task}`} />
                                        ) : (
                                            <>
                                                <input type="file" id={`photo-upload-${item.id}`} accept="image/*" capture="environment" onChange={(e) => handlePhotoCapture(item.id, e)} disabled={index !== activeItemIndex} />
                                                <label htmlFor={`photo-upload-${item.id}`} className={`action-button ${index !== activeItemIndex ? 'sr-only' : ''}`} aria-label={`拍攝 ${item.task}`}>拍攝照片</label>
                                            </>
                                        )}
                                    </div>
                                </li>
                            ))}
                        </ul>
                         <div className="actions-bar">
                            <button onClick={startAnalysis} disabled={!allPhotosTaken} className="button-primary">
                                開始分析所有項目
                            </button>
                        </div>
                    </section>
                );
            case 'ANALYZING':
                const analyzedCount = checklist.filter(i => i.status === 'success' || i.status === 'error' || i.status === 'loading').length;
                return <LoadingComponent text={`正在分析照片... (${analyzedCount} / ${checklist.length})`} />;
            case 'REVIEW':
                 const unconfirmedSuccessCount = checklist.filter(i => i.status === 'success').length;
                return (
                    <section>
                         <h2>步驟 3: 分析與審核結果</h2>
                        <div className="actions-bar">
                            <button onClick={handleConfirmAll} disabled={unconfirmedSuccessCount === 0}>
                                一鍵記錄所有已完成項目 ({unconfirmedSuccessCount})
                            </button>
                        </div>
                        <div className="inspection-grid" role="list">
                            {checklist.map((item: ChecklistItem) => (
                                <InspectionCard key={item.id} item={item} onConfirm={handleConfirmOne} onRetry={handlePhotoRetry} />
                            ))}
                        </div>
                    </section>
                );
            default:
                return null;
        }
    };

    return (
        <div className="container" role="main">
            <header>
                <h1>InduSpect AI 智慧巡檢</h1>
                <p>一個更智慧、更引導式的巡檢流程。</p>
            </header>
            <Stepper appState={appState} />
            <main>
                {renderContent()}
                <RecordsTable records={confirmedRecords} />
            </main>
            <footer>
                <p>由 Google Gemini 驅動</p>
            </footer>
        </div>
    );
};

const root = ReactDOM.createRoot(document.getElementById('root')!);
root.render(<App />);