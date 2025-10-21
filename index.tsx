
import React, { useState, useCallback, useId, useEffect, useRef } from 'react';
import ReactDOM from 'react-dom/client';
import { GoogleGenAI, Type } from "@google/genai";

// --- Custom Hooks ---
const usePersistentState = <T,>(key: string, initialValue: T): [T, React.Dispatch<React.SetStateAction<T>>] => {
    const [state, setState] = useState<T>(() => {
        try {
            const storedValue = window.localStorage.getItem(key);
            return storedValue ? JSON.parse(storedValue) : initialValue;
        } catch (error) {
            console.error(`Error reading localStorage key “${key}”:`, error);
            return initialValue;
        }
    });

    useEffect(() => {
        try {
            window.localStorage.setItem(key, JSON.stringify(state));
        } catch (error) {
            console.error(`Error setting localStorage key “${key}”:`, error);
        }
    }, [key, state]);

    return [state, setState];
};


// --- Type Definitions ---
interface Point { x: number; y: number; }
interface Line { p1: Point; p2: Point; }
interface MeasurementLines {
    ref: Line | null;
    target: Line | null;
}
interface Dimension {
    object_name: string | null;
    value: number | null;
    unit: string | null;
}
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
    dimensions: Dimension | null;
    measurementLines?: MeasurementLines | null;
}

type ChecklistItemStatus = 'pending' | 'capturing' | 'captured' | 'loading' | 'success' | 'error' | 'confirmed';

interface ChecklistItem {
    id: string;
    task: string;
    dataUrl: string | null;
    mimeType: string | null;
    imageDimensions?: { width: number; height: number; } | null;
    status: ChecklistItemStatus;
    result: AnalysisResult | null;
    error: string | null;
}

type AppState = 'IDLE' | 'EXTRACTING' | 'CAPTURE' | 'ANALYZING' | 'REVIEW' | 'QUICK_ANALYSIS_CAPTURE' | 'QUICK_ANALYSIS_ANALYZING' | 'QUICK_ANALYSIS_REVIEW';
type ReportState = 'idle' | 'generating' | 'error';

// --- Helper Functions ---
const dataUrlToGenerativePart = (dataUrl: string, mimeType: string) => {
    const base64Data = dataUrl.split(',')[1];
    return {
        inlineData: { data: base64Data, mimeType: mimeType },
    };
};

const processImageFile = (file: File): Promise<{ dataUrl: string; dimensions: { width: number, height: number } }> => {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = (e_reader) => {
            const dataUrl = e_reader.target!.result as string;
            const img = new Image();
            img.onload = () => {
                resolve({
                    dataUrl,
                    dimensions: { width: img.naturalWidth, height: img.naturalHeight }
                });
            };
            img.onerror = (err) => reject(err);
            img.src = dataUrl;
        };
        reader.onerror = (err) => reject(err);
        reader.readAsDataURL(file);
    });
};

const fileToDataUrl = (file: File): Promise<string> => {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result as string);
        reader.onerror = reject;
        reader.readAsDataURL(file);
    });
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
    
    if (appState.startsWith('QUICK_ANALYSIS')) {
        return null;
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

const ImageWithMeasurementOverlay: React.FC<{
    src: string;
    alt: string;
    lines?: MeasurementLines | null;
    dimensions?: { width: number, height: number } | null;
}> = ({ src, alt, lines, dimensions }) => {
    return (
        <div className="image-overlay-container">
            <img src={src} alt={alt} />
            {lines && dimensions && (
                <svg
                    className="measurement-overlay"
                    viewBox={`0 0 ${dimensions.width} ${dimensions.height}`}
                >
                    {lines.ref && (
                        <line
                            x1={lines.ref.p1.x} y1={lines.ref.p1.y}
                            x2={lines.ref.p2.x} y2={lines.ref.p2.y}
                            stroke="#42a5f5" strokeWidth="40" strokeOpacity="0.9"
                        />
                    )}
                    {lines.target && (
                        <line
                            x1={lines.target.p1.x} y1={lines.target.p1.y}
                            x2={lines.target.p2.x} y2={lines.target.p2.y}
                            stroke="#d32f2f" strokeWidth="40" strokeOpacity="0.9"
                        />
                    )}
                </svg>
            )}
        </div>
    );
};


const ImageMeasurementTool: React.FC<{
    imageUrl: string;
    onComplete: (dim: Dimension, lines: MeasurementLines) => void;
    onClose: () => void;
}> = ({ imageUrl, onComplete, onClose }) => {
    const canvasRef = useRef<HTMLCanvasElement>(null);
    const [stage, setStage] = useState<'draw_reference' | 'enter_reference' | 'draw_target' | 'done'>('draw_reference');
    const [lines, setLines] = useState<MeasurementLines>({ ref: null, target: null });
    const [startPoint, setStartPoint] = useState<Point | null>(null);
    const [mousePos, setMousePos] = useState<Point | null>(null);
    const [refLength, setRefLength] = useState<string>('85.6'); // Default to credit card width in mm
    const [refUnit, setRefUnit] = useState<string>('mm');

    const draw = useCallback(() => {
        const canvas = canvasRef.current;
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        
        const img = new Image();
        img.src = imageUrl;
        img.onload = () => {
            canvas.width = img.width;
            canvas.height = img.height;
            ctx.drawImage(img, 0, 0);

            // Draw completed lines
            ctx.lineWidth = 5;
            if (lines.ref) {
                ctx.strokeStyle = '#42a5f5'; // Light Blue
                ctx.beginPath();
                ctx.moveTo(lines.ref.p1.x, lines.ref.p1.y);
                ctx.lineTo(lines.ref.p2.x, lines.ref.p2.y);
                ctx.stroke();
            }
            if (lines.target) {
                ctx.strokeStyle = '#d32f2f'; // Red
                ctx.beginPath();
                ctx.moveTo(lines.target.p1.x, lines.target.p1.y);
                ctx.lineTo(lines.target.p2.x, lines.target.p2.y);
                ctx.stroke();
            }

            // Draw currently drawing line
            if (startPoint && mousePos) {
                 ctx.strokeStyle = stage === 'draw_reference' ? '#42a5f5' : '#d32f2f';
                 ctx.beginPath();
                 ctx.moveTo(startPoint.x, startPoint.y);
                 ctx.lineTo(mousePos.x, mousePos.y);
                 ctx.stroke();
            }
        }
    }, [imageUrl, lines, startPoint, mousePos, stage]);

    useEffect(() => {
        draw();
    }, [draw]);

    const getCanvasCoords = (e: React.MouseEvent<HTMLCanvasElement>): Point => {
        const canvas = canvasRef.current;
        if (!canvas) return { x: 0, y: 0 };
        const rect = canvas.getBoundingClientRect();
        const scaleX = canvas.width / rect.width;
        const scaleY = canvas.height / rect.height;
        return {
            x: (e.clientX - rect.left) * scaleX,
            y: (e.clientY - rect.top) * scaleY,
        };
    };

    const handleMouseDown = (e: React.MouseEvent<HTMLCanvasElement>) => {
        if (stage !== 'draw_reference' && stage !== 'draw_target') return;
        setStartPoint(getCanvasCoords(e));
    };

    const handleMouseMove = (e: React.MouseEvent<HTMLCanvasElement>) => {
        if (!startPoint) return;
        setMousePos(getCanvasCoords(e));
    };

    const handleMouseUp = (e: React.MouseEvent<HTMLCanvasElement>) => {
        if (!startPoint) return;
        const endPoint = getCanvasCoords(e);
        if (stage === 'draw_reference') {
            setLines(prev => ({ ...prev, ref: {p1: startPoint, p2: endPoint} }));
            setStage('enter_reference');
        } else if (stage === 'draw_target') {
            setLines(prev => ({ ...prev, target: {p1: startPoint, p2: endPoint} }));
            setStage('done');
        }
        setStartPoint(null);
        setMousePos(null);
    };

    const calculateDistance = (p1: Point, p2: Point) => Math.sqrt(Math.pow(p2.x - p1.x, 2) + Math.pow(p2.y - p1.y, 2));

    const handleCalculation = () => {
        if (!lines.ref || !lines.target || !refLength) return;

        const refPixelLength = calculateDistance(lines.ref.p1, lines.ref.p2);
        const targetPixelLength = calculateDistance(lines.target.p1, lines.target.p2);
        const realRefLength = parseFloat(refLength);

        if (refPixelLength === 0 || isNaN(realRefLength)) return;

        const pixelsPerUnit = refPixelLength / realRefLength;
        const realTargetLength = targetPixelLength / pixelsPerUnit;

        onComplete({
            object_name: "手動測量裂縫",
            value: parseFloat(realTargetLength.toFixed(2)),
            unit: refUnit,
        }, lines);
    };

    const getInstruction = () => {
        switch (stage) {
            case 'draw_reference': return '步驟 1: 請在參考物 (如信用卡) 上拖曳畫線';
            case 'enter_reference': return '步驟 2: 輸入參考物的實際長度與單位';
            case 'draw_target': return '步驟 3: 在您要測量的物體上拖曳畫線';
            case 'done': return '步驟 4: 完成測量！';
            default: return '';
        }
    };
    
    const handleReset = () => {
        setLines({ ref: null, target: null });
        setStage('draw_reference');
    }

    return (
        <div className="measurement-modal-overlay">
            <div className="measurement-modal">
                <div className="measurement-header">
                    <h3>互動式尺寸測量工具</h3>
                    <button onClick={onClose} className="close-button">&times;</button>
                </div>
                <div className="measurement-instructions">{getInstruction()}</div>
                <div className="measurement-canvas-container">
                    <canvas 
                        ref={canvasRef}
                        onMouseDown={handleMouseDown}
                        onMouseMove={handleMouseMove}
                        onMouseUp={handleMouseUp}
                    />
                </div>
                <div className="measurement-controls">
                    {stage === 'enter_reference' && (
                        <>
                            <input type="number" value={refLength} onChange={e => setRefLength(e.target.value)} placeholder="長度" />
                            <input type="text" value={refUnit} onChange={e => setRefUnit(e.target.value)} placeholder="單位" />
                            <button onClick={() => setStage('draw_target')}>確認參考</button>
                        </>
                    )}
                    {stage === 'done' && <button onClick={handleCalculation}>完成並儲存</button>}
                    <button onClick={handleReset} className="button-secondary">重設</button>
                </div>
            </div>
        </div>
    );
};


const InspectionCard: React.FC<{
    item: ChecklistItem,
    onConfirm?: (id: string) => void,
    onSave?: (id: string) => void,
    onRetry: (id: string, eventOrFile: React.ChangeEvent<HTMLInputElement> | File) => void,
    onUpdateResult: (id: string, result: AnalysisResult) => void,
    onReanalyze?: (id: string, supplementalPrompt: string) => void,
    isQuickMode?: boolean,
}> = ({ item, onConfirm, onSave, onRetry, onUpdateResult, onReanalyze, isQuickMode = false }) => {
    const [isMeasuring, setIsMeasuring] = useState(false);
    const [supplementalPrompt, setSupplementalPrompt] = useState('');

    const handleResultChange = <K extends keyof AnalysisResult>(field: K, value: AnalysisResult[K]) => {
        if (!item.result) return;
        onUpdateResult(item.id, { ...item.result, [field]: value });
    };

    const handleReadingChange = (index: number, field: 'label' | 'value' | 'unit', value: string | number | null) => {
        if (!item.result || !item.result.readings) return;
        const newReadings = [...item.result.readings];
        newReadings[index] = { ...newReadings[index], [field]: value };
        handleResultChange('readings', newReadings);
    };

    const handleDimensionChange = (field: keyof Dimension, value: string | number | null) => {
         if (!item.result) return;
         const newDimension = { ...(item.result.dimensions || { object_name: '', value: null, unit: '' }), [field]: value };
         handleResultChange('dimensions', newDimension);
    }
    
    const handleMeasurementComplete = (dim: Dimension, lines: MeasurementLines) => {
        if (!item.result) return;
        const newResult = { ...item.result, dimensions: dim, measurementLines: lines };
        onUpdateResult(item.id, newResult);
        setIsMeasuring(false);
    }

    const renderEditableResult = (result: AnalysisResult) => (
        <div className="results-container editable">
            <div className="result-item">
                <label htmlFor={`equipment-type-${item.id}`}>設備類型</label>
                <input
                    type="text"
                    id={`equipment-type-${item.id}`}
                    value={result.equipment_type}
                    onChange={(e) => handleResultChange('equipment_type', e.target.value)}
                />
            </div>
             <div className="result-item">
                <label>儀表讀數</label>
                {result.readings && result.readings.length > 0 ? (
                    <div className="readings-grid editable">
                        {result.readings.map((reading, index) => (
                            <div key={index} className="reading-inputs">
                                <input type="text" aria-label="Reading Label" placeholder="標籤" value={reading.label} onChange={(e) => handleReadingChange(index, 'label', e.target.value)} />
                                <input type="number" aria-label="Reading Value" placeholder="數值" value={reading.value ?? ''} onChange={(e) => handleReadingChange(index, 'value', e.target.value === '' ? null : parseFloat(e.target.value))} />
                                <input type="text" aria-label="Reading Unit" placeholder="單位" value={reading.unit ?? ''} onChange={(e) => handleReadingChange(index, 'unit', e.target.value)} />
                            </div>
                        ))}
                    </div>
                ) : ( <span>無</span> )}
            </div>
            <div className="result-item">
                <label>測量尺寸 (AI 或手動)</label>
                 <div className="dimension-inputs">
                    <input type="text" aria-label="Dimension Object" placeholder="測量目標" value={result.dimensions?.object_name ?? ''} onChange={e => handleDimensionChange('object_name', e.target.value)} />
                    <input type="number" aria-label="Dimension Value" placeholder="數值" value={result.dimensions?.value ?? ''} onChange={e => handleDimensionChange('value', e.target.value === '' ? null : parseFloat(e.target.value))} />
                    <input type="text" aria-label="Dimension Unit" placeholder="單位" value={result.dimensions?.unit ?? ''} onChange={e => handleDimensionChange('unit', e.target.value)} />
                </div>
            </div>
            <div className="result-item">
                <label htmlFor={`condition-${item.id}`}>狀況評估</label>
                <textarea id={`condition-${item.id}`} value={result.condition_assessment} onChange={(e) => handleResultChange('condition_assessment', e.target.value)} rows={3} />
            </div>
            <div className="result-item anomaly-toggle">
                <label htmlFor={`anomaly-${item.id}`}>偵測到異常</label>
                <div className="toggle-switch">
                    <input type="checkbox" id={`anomaly-${item.id}`} checked={result.is_anomaly} onChange={(e) => handleResultChange('is_anomaly', e.target.checked)} />
                    <label htmlFor={`anomaly-${item.id}`}></label>
                </div>
                <span className={result.is_anomaly ? 'anomaly' : 'no-anomaly'}>{result.is_anomaly ? '是' : '否'}</span>
            </div>
            <div className="result-item summary">
                <label htmlFor={`summary-${item.id}`}>AI 總結</label>
                <textarea id={`summary-${item.id}`} value={result.summary} onChange={(e) => handleResultChange('summary', e.target.value)} rows={4} />
            </div>
            {onReanalyze && (
                <div className="reanalysis-section">
                    <label htmlFor={`reanalyze-prompt-${item.id}`}>補充提示或說明</label>
                    <textarea
                        id={`reanalyze-prompt-${item.id}`}
                        placeholder="例如：請專注於右下角的閥門，並忽略背景中的其他管道。"
                        value={supplementalPrompt}
                        onChange={(e) => setSupplementalPrompt(e.target.value)}
                        rows={3}
                    />
                    <button onClick={() => onReanalyze(item.id, supplementalPrompt)} className="button-secondary">
                        使用提示重新分析
                    </button>
                </div>
            )}
        </div>
    );
    
    const renderStaticResult = (result: AnalysisResult) => (
        <div className="results-container">
            <div className="result-item"><strong>設備類型：</strong><span>{result.equipment_type}</span></div>
            <div className="result-item">
                <strong>儀表讀數：</strong>
                {result.readings && result.readings.length > 0 ? (
                    <div className="readings-grid">
                        {result.readings.map((reading, index) => (
                            <div key={index} className="reading">
                                <span className="reading-label">{reading.label}:</span>
                                <span className="reading-value">{reading.value !== null && reading.value !== undefined ? `${reading.value} ${reading.unit || ''}`.trim() : 'N/A'}</span>
                            </div>
                        ))}
                    </div>
                ) : (<span>無</span>)}
            </div>
             <div className="result-item">
                <strong>測量尺寸：</strong>
                <span>{result.dimensions?.value ? `${result.dimensions.object_name}: ${result.dimensions.value} ${result.dimensions.unit}` : '無'}</span>
            </div>
            <div className="result-item"><strong>狀況評估：</strong><p>{result.condition_assessment}</p></div>
            <div className="result-item">
                <strong>偵測到異常：</strong>
                <span className={result.is_anomaly ? 'anomaly' : 'no-anomaly'}>{result.is_anomaly ? '是' : '否'}</span>
            </div>
             <div className="result-item summary"><strong>AI 總結：</strong><p>{result.summary}</p></div>
        </div>
    );
    
    return (
        <>
        {isMeasuring && item.dataUrl && <ImageMeasurementTool imageUrl={item.dataUrl} onComplete={handleMeasurementComplete} onClose={() => setIsMeasuring(false)} />}
        <div className={`inspection-card ${item.status === 'confirmed' ? 'confirmed' : ''}`} role="listitem">
           <h3 className="card-header">{item.task}</h3>
           <div className="card-content">
                <div className="image-container">
                    {item.dataUrl && (
                        <ImageWithMeasurementOverlay 
                            src={item.dataUrl}
                            alt={`預覽 ${item.task}`}
                            lines={item.result?.measurementLines}
                            dimensions={item.imageDimensions}
                        />
                    )}
                    {item.status === 'loading' && <div className="loader" role="status" aria-label="分析加載中"></div>}
                </div>
                <div style={{flex: '1 1 60%'}}>
                    {item.status === 'success' && item.result && renderEditableResult(item.result)}
                    {item.status === 'confirmed' && item.result && renderStaticResult(item.result)}
                    {item.status === 'error' && <div className="error-message" role="alert">{item.error}</div>}
                </div>
           </div>
            <div className="card-actions">
                {item.status === 'success' && (
                    <button onClick={() => setIsMeasuring(true)} className="button-secondary">手動測量尺寸</button>
                )}
                {item.status === 'error' && (
                    <>
                        <input type="file" id={`retry-upload-${item.id}`} accept="image/*" capture="environment" onChange={(e) => onRetry(item.id, e)} style={{ display: 'none' }} />
                        <label htmlFor={`retry-upload-${item.id}`} className="button-retry">重新拍攝並分析</label>
                    </>
                )}
                 {isQuickMode && onSave && item.status === 'success' && (
                    <button onClick={() => onSave(item.id)}>儲存此記錄</button>
                )}
                {!isQuickMode && onConfirm && (
                    <button onClick={() => onConfirm(item.id)} disabled={item.status !== 'success'}>
                        {item.status === 'confirmed' ? '已記錄' : '確認記錄'}
                    </button>
                )}
            </div>
        </div>
        </>
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
                            <th>測量尺寸</th>
                            <th>AI 總結</th>
                            <th>異常?</th>
                        </tr>
                    </thead>
                    <tbody>
                        {records.map((record, index) => (
                            <tr key={record.id}>
                                <td>{index + 1}</td>
                                <td>{record.task}</td>
                                <td>
                                    {record.dataUrl && (
                                        <ImageWithMeasurementOverlay
                                            src={record.dataUrl}
                                            alt={record.task}
                                            lines={record.result?.measurementLines}
                                            dimensions={record.imageDimensions}
                                        />
                                    )}
                                </td>
                                <td>{record.result?.equipment_type}</td>
                                <td>{record.result?.readings.map(r => `${r.label}: ${r.value ?? 'N/A'} ${r.unit ?? ''}`).join(', ') || 'N/A'}</td>
                                <td>{record.result?.dimensions?.value ? `${record.result.dimensions.object_name}: ${record.result.dimensions.value} ${record.result.dimensions.unit}` : 'N/A'}</td>
                                <td>{record.result?.summary}</td>
                                <td>
                                    <span className={record.result?.is_anomaly ? 'anomaly' : 'no-anomaly'}>{record.result?.is_anomaly ? '是' : '否'}</span>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </section>
    );
};

const ReportSection = ({
    records,
    report,
    reportState,
    reportError,
    onGenerate,
}: {
    records: ChecklistItem[];
    report: string | null;
    reportState: ReportState;
    reportError: string | null;
    onGenerate: () => void;
}) => {
    if (records.length === 0) {
        return null;
    }

    return (
        <section className="report-section" aria-labelledby="report-heading">
            <h2 id="report-heading">巡檢總結報告</h2>
            <div className="actions-bar">
                 <button onClick={onGenerate} disabled={reportState === 'generating'} className="button-generate-report">
                    {reportState === 'generating' ? '報告生成中...' : '產生總結報告'}
                </button>
            </div>
           
            {reportState === 'generating' && <LoadingComponent text="正在分析所有記錄並生成報告..." />}
            {reportState === 'error' && <div className="error-message" role="alert">{reportError}</div>}
            {report && (
                <div className="report-content">
                    <pre>{report}</pre>
                </div>
            )}
        </section>
    );
};


// --- Main App Component ---

const App = () => {
    const [appState, setAppState] = usePersistentState<AppState>('appState', 'IDLE');
    const [checklist, setChecklist] = usePersistentState<ChecklistItem[]>('checklist', []);
    const [confirmedRecords, setConfirmedRecords] = usePersistentState<ChecklistItem[]>('confirmedRecords', []);
    const [quickAnalysisItem, setQuickAnalysisItem] = useState<ChecklistItem | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [report, setReport] = usePersistentState<string | null>('report', null);
    const [reportState, setReportState] = usePersistentState<ReportState>('reportState', 'idle');
    const [reportError, setReportError] = useState<string | null>(null);
    const [isOnline, setIsOnline] = useState(navigator.onLine);
    const uniqueId = useId();

    useEffect(() => {
        // On initial load, reset any states that shouldn't persist across sessions.
        
        // 1. Reset 'QUICK_ANALYSIS' app states because the photo data isn't persisted.
        const storedStateJSON = window.localStorage.getItem('appState');
        if (storedStateJSON) {
            try {
                const lastState = JSON.parse(storedStateJSON);
                if (typeof lastState === 'string' && lastState.startsWith('QUICK_ANALYSIS')) {
                    setAppState('IDLE');
                }
            } catch (e) {
                console.error("Error parsing persisted app state:", e);
                setAppState('IDLE');
            }
        }
        
        // 2. Reset report generation state if it was stuck on 'generating' from a previous session.
        const storedReportStateJSON = window.localStorage.getItem('reportState');
        if (storedReportStateJSON) {
            try {
                const lastReportState = JSON.parse(storedReportStateJSON);
                if (lastReportState === 'generating') {
                    setReportState('idle');
                }
            } catch (e) {
                console.error("Error parsing persisted report state:", e);
                setReportState('idle');
            }
        }
    }, []); // Run only once on component mount
    
    useEffect(() => {
        const handleOnline = () => setIsOnline(true);
        const handleOffline = () => setIsOnline(false);

        window.addEventListener('online', handleOnline);
        window.addEventListener('offline', handleOffline);

        return () => {
            window.removeEventListener('online', handleOnline);
            window.removeEventListener('offline', handleOffline);
        };
    }, []);

    const handleFormUpload = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        setAppState('EXTRACTING');
        setError(null);

        try {
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
            const imagePart = dataUrlToGenerativePart(await fileToDataUrl(file), file.type);

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
                dataUrl: null,
                mimeType: null,
                imageDimensions: null,
                status: 'pending',
                result: null,
                error: null,
            }));

            if(newChecklist.length === 0) {
                throw new Error("無法從文件中提取任何檢查項目。");
            }

            setChecklist(newChecklist);
            setConfirmedRecords([]);
            setReport(null);
            setReportState('idle');
            setQuickAnalysisItem(null);
            setAppState('CAPTURE');

        } catch (e: any) {
            console.error(e);
            setError(`無法分析定檢表: ${e.message}`);
            setAppState('IDLE');
        } finally {
             event.target.value = '';
        }
    }, [uniqueId, setAppState, setChecklist, setConfirmedRecords, setReport, setReportState, setQuickAnalysisItem]);

    const handlePhotoCapture = async (itemId: string, event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        try {
            const { dataUrl, dimensions } = await processImageFile(file);
            setChecklist(prev => prev.map(item =>
                item.id === itemId ? {
                    ...item,
                    dataUrl,
                    mimeType: file.type,
                    imageDimensions: dimensions,
                    status: 'captured'
                } : item
            ));
        } catch (error) {
            console.error("Error converting file to data URL:", error);
            // Optionally set an error state on the specific item
        } finally {
            event.target.value = '';
        }
    };

    const runAnalysis = useCallback(async (
        itemToAnalyze: ChecklistItem,
        onSuccess: (item: ChecklistItem, result: AnalysisResult) => void,
        onError: (item: ChecklistItem, errorMessage: string) => void,
        supplementalPrompt?: string
    ) => {
        if (!itemToAnalyze.dataUrl || !itemToAnalyze.mimeType) {
            onError(itemToAnalyze, "圖像數據遺失。");
            return;
        };

        try {
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });
            const imagePart = dataUrlToGenerativePart(itemToAnalyze.dataUrl, itemToAnalyze.mimeType);

            const basePrompt = `您是一位專業且謹慎的工業巡檢 AI。您的任務是驗證圖像並進行詳細分析，包括潛在的尺寸測量。

巡檢任務： "${itemToAnalyze.task}"

第一階段：圖像驗證
1.  **相關性檢查**：圖像中的主要物體是否與「巡檢任務」相符？ (如果是通用分析，請跳過此步)
2.  **品質檢查**：圖像是否清晰、光線充足，足以進行準確分析？

第二階段：條件式分析
- **如果驗證失敗**：請立即停止，並在 'validation_error' 欄位中用繁體中文清楚說明原因。
- **如果驗證成功**：請繼續進行詳細分析，並遵循以下的「思維鏈」步驟。

思維鏈分析步驟：
1.  **場景描述與設備識別**: 簡要描述場景，精確識別主要設備類型。
2.  **數據讀取**: 掃描所有儀表、刻度盤或數字顯示屏，讀取標籤、數值和單位。
3.  **狀況評估**: 評估設備的物理狀況，尋找任何生鏽、洩漏、裂縫等異常跡象。
4.  **尺寸測量 (可選)**:
    -   檢查圖像中是否存在一個標準尺寸的信用卡 (寬度 85.6mm) 作為參照物。
    -   如果**同時**存在信用卡和一個明顯的、需要測量的異常特徵（如裂縫），請以此信用卡為比例尺，估算該特徵的真實尺寸（單位為 mm）。
    -   如果沒有信用卡或沒有需要測量的特徵，請將 'dimensions' 欄位設為 null。
5.  **綜合判斷**: 基於以上觀察，判斷是否存在異常，並撰寫一個簡潔的總結。`;

            const supplementalInstruction = supplementalPrompt
                ? `\n\n重要補充說明與重新分析指令：
使用者對先前的分析結果提供了以下補充說明。請將此說明作為最高優先級，並根據它重新進行完整的思維鏈分析。
使用者補充說明：“${supplementalPrompt}”`
                : '';

            const prompt = `${basePrompt}${supplementalInstruction}\n\n輸出格式：
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
                            readings: { type: Type.ARRAY, items: { type: Type.OBJECT, properties: { label: { type: Type.STRING }, value: { type: Type.NUMBER, nullable: true }, unit: { type: Type.STRING, nullable: true } }, required: ["label"] }},
                            condition_assessment: { type: Type.STRING },
                            is_anomaly: { type: Type.BOOLEAN },
                            summary: { type: Type.STRING },
                            dimensions: { type: Type.OBJECT, nullable: true, properties: { object_name: { type: Type.STRING }, value: { type: Type.NUMBER }, unit: { type: Type.STRING } }, required: ["object_name", "value", "unit"] }
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
                onSuccess(itemToAnalyze, resultJson.analysis);
            } else {
                const errorMessage = resultJson.validation_error || "圖像驗證失敗，但未提供具體原因。";
                throw new Error(errorMessage);
            }

        } catch (e: any) {
            console.error(e);
            onError(itemToAnalyze, `分析失敗: ${e.message}`);
        }
    }, []);
    
    const startAnalysis = useCallback(async () => {
        if (!isOnline) {
            alert("目前處於離線狀態，請連接網路後再試。");
            return;
        }
        setAppState('ANALYZING');
        const itemsToAnalyze = checklist.filter(item => item.status === 'captured' && item.dataUrl);
        
        const itemIdsToAnalyze = itemsToAnalyze.map(i => i.id);
        setChecklist(prev => prev.map(item => 
            itemIdsToAnalyze.includes(item.id) ? { ...item, status: 'loading' } : item
        ));
        
        const analysisPromises = itemsToAnalyze.map(item => runAnalysis(
            item, 
            (_, result) => {
                setChecklist(prev => prev.map(i => i.id === item.id ? { ...i, status: 'success', result } : i));
            },
            (_, errorMsg) => {
                setChecklist(prev => prev.map(i => i.id === item.id ? { ...i, status: 'error', error: errorMsg } : i));
            }
        ));
        await Promise.all(analysisPromises);
        setAppState('REVIEW');
    }, [checklist, runAnalysis, isOnline, setAppState, setChecklist]);

    const handleUpdateResult = (itemId: string, updatedResult: AnalysisResult) => {
        const updateLogic = (item: ChecklistItem) => 
            item.id === itemId && item.result
                ? { ...item, result: updatedResult }
                : item;

        if (appState === 'QUICK_ANALYSIS_REVIEW') {
             setQuickAnalysisItem(prev => (prev && prev.id === itemId) ? updateLogic(prev) : prev);
        } else {
            setChecklist(prev => prev.map(updateLogic));
        }
    };


    const handlePhotoRetry = async (itemId: string, event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        try {
            const { dataUrl, dimensions } = await processImageFile(file);
            const itemToUpdate = checklist.find(i => i.id === itemId);
            if (!itemToUpdate) return;
            
            const updatedItem: ChecklistItem = { 
                ...itemToUpdate, 
                dataUrl, 
                mimeType: file.type, 
                imageDimensions: dimensions,
                status: 'loading', 
                error: null, 
                result: null 
            };
            setChecklist(prev => prev.map(i => i.id === itemId ? updatedItem : i));
            
            if (isOnline) {
                runAnalysis(updatedItem, 
                    (_, result) => setChecklist(prev => prev.map(i => i.id === itemId ? { ...i, status: 'success', result } : i)),
                    (_, errorMsg) => setChecklist(prev => prev.map(i => i.id === itemId ? { ...i, status: 'error', error: errorMsg } : i))
                );
            } else {
                 setChecklist(prev => prev.map(i => i.id === itemId ? { ...updatedItem, status: 'captured' } : i));
                 alert("已在離線狀態下更新照片。請在連線後點擊分析。");
            }
            
        } catch (error) {
             console.error("Error during retry:", error);
        } finally {
            event.target.value = '';
        }
    };
    
    // --- Quick Analysis Mode Handlers ---
    const handleQuickPhoto = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file) return;

        try {
            const { dataUrl, dimensions } = await processImageFile(file);
            const newItem: ChecklistItem = {
                id: `quick-${Date.now()}`,
                task: '快速分析',
                dataUrl,
                mimeType: file.type,
                imageDimensions: dimensions,
                status: 'loading',
                result: null,
                error: null,
            };
            setQuickAnalysisItem(newItem);
            setAppState('QUICK_ANALYSIS_ANALYZING');
            
            runAnalysis(newItem,
                (_, result) => {
                    setQuickAnalysisItem(prev => prev ? { ...prev, status: 'success', result } : null);
                    setAppState('QUICK_ANALYSIS_REVIEW');
                },
                (_, errorMsg) => {
                    setQuickAnalysisItem(prev => prev ? { ...prev, status: 'error', error: errorMsg } : null);
                    setAppState('QUICK_ANALYSIS_REVIEW');
                }
            );

        } catch (error) {
             console.error("Error in quick photo analysis:", error);
             setQuickAnalysisItem(null);
             setAppState('QUICK_ANALYSIS_CAPTURE');
        } finally {
            event.target.value = '';
        }

    }, [runAnalysis, setAppState, setQuickAnalysisItem]);
    
    const handleQuickPhotoRetry = async (itemId: string, event: React.ChangeEvent<HTMLInputElement>) => {
        const file = event.target.files?.[0];
        if (!file || !quickAnalysisItem || quickAnalysisItem.id !== itemId) return;

        try {
            const { dataUrl, dimensions } = await processImageFile(file);
            
            const updatedItem: ChecklistItem = { 
                ...quickAnalysisItem, 
                dataUrl, 
                mimeType: file.type,
                imageDimensions: dimensions,
                status: 'loading', 
                error: null, 
                result: null 
            };
            setQuickAnalysisItem(updatedItem);
            setAppState('QUICK_ANALYSIS_ANALYZING');
            
            runAnalysis(updatedItem, 
                (_, result) => {
                    setQuickAnalysisItem(prev => prev ? { ...prev, status: 'success', result } : null);
                    setAppState('QUICK_ANALYSIS_REVIEW');
                },
                (_, errorMsg) => {
                    setQuickAnalysisItem(prev => prev ? { ...prev, status: 'error', error: errorMsg } : null);
                    setAppState('QUICK_ANALYSIS_REVIEW');
                }
            );
            
        } catch (error) {
             console.error("Error during quick photo retry:", error);
             setQuickAnalysisItem(prev => prev ? { ...prev, status: 'error', error: '重試時發生錯誤' } : null);
             setAppState('QUICK_ANALYSIS_REVIEW');
        } finally {
            event.target.value = '';
        }
    };

    const handleSaveQuickAnalysis = (id: string) => {
        if (!quickAnalysisItem || quickAnalysisItem.id !== id || quickAnalysisItem.status !== 'success') return;

        const newConfirmedItem = { ...quickAnalysisItem, status: 'confirmed' as ChecklistItemStatus, task: `快速分析 - ${quickAnalysisItem.result?.equipment_type || '未知設備'}` };
        setConfirmedRecords(prev => [...prev, newConfirmedItem]);

        // Reset for next quick analysis
        setQuickAnalysisItem(null);
        setAppState('QUICK_ANALYSIS_CAPTURE');
    };

    const handleConfirmOne = (id: string) => {
        const itemToConfirm = checklist.find(item => item.id === id);
        if (!itemToConfirm || itemToConfirm.status !== 'success') return;
        
        const remainingChecklist = checklist.filter(item => item.id !== id);
        const newConfirmedItem = { ...itemToConfirm, status: 'confirmed' as ChecklistItemStatus };

        setChecklist(remainingChecklist);
        setConfirmedRecords(prev => [...prev, newConfirmedItem]);
    };
    
    const handleConfirmAll = () => {
        const itemsToConfirm = checklist.filter(item => item.status === 'success');
        if (itemsToConfirm.length === 0) return;
        
        const confirmedIds = itemsToConfirm.map(item => item.id);
        const remainingChecklist = checklist.filter(item => !confirmedIds.includes(item.id));
        const newConfirmedItems = itemsToConfirm.map(item => ({...item, status: 'confirmed' as ChecklistItemStatus}));
        
        setChecklist(remainingChecklist);
        setConfirmedRecords(prev => [...prev, ...newConfirmedItems]);
    };

    const handleGenerateReport = useCallback(async () => {
        setReportState('generating');
        setReport(null);
        setReportError(null);

        if (confirmedRecords.length === 0) {
            setReportError("沒有已確認的記錄可供生成報告。");
            setReportState('error');
            return;
        }

        try {
            const ai = new GoogleGenAI({ apiKey: process.env.API_KEY });

            const reportInputData = confirmedRecords.map(item => {
                const result = item.result;
                if (!result) return null;
                const primaryReading = result.readings && result.readings.length > 0 ? result.readings[0] : null;
                return {
                    inspection_point: item.task,
                    equipment_type: result.equipment_type,
                    reading: primaryReading ? { value: primaryReading.value, unit: primaryReading.unit } : null,
                    condition_assessment: result.condition_assessment,
                    is_anomaly: result.is_anomaly
                };
            }).filter(Boolean);

            const prompt = `您是一位經驗豐富的工廠營運經理 AI 助理。

背景資料：
以下是一個 JSON 陣列，包含了某次設施巡檢中每個檢查點的數據。每個物件代表一個巡檢點的發現。
${JSON.stringify(reportInputData, null, 2)}

任務指令：
請根據上述數據，生成一份不超過 250 字的高階主管級摘要報告。報告應包含以下三個部分：
1.  **總體概述**: 簡要總結本次巡檢的整體情況。
2.  **關鍵問題**: 以點列方式，列出最多 3 個最需要立即關注的異常問題，並明確指出設備位置和具體問題。
3.  **結論**: 用一句話總結設施的整體維護狀況。

報告語氣應正式、專業且簡潔。直接輸出報告內容，不要包含任何額外的開場白或結語。`;

            const response = await ai.models.generateContent({
                model: 'gemini-2.5-flash',
                contents: prompt,
            });

            setReport(response.text);
            setReportState('idle');

        } catch (e: any) {
            console.error("Report generation failed:", e);
            setReportError(`報告生成失敗: ${e.message}`);
            setReportState('error');
        }
    }, [confirmedRecords, setReport, setReportError, setReportState]);
    
    const handleReanalyze = useCallback(async (itemId: string, supplementalPrompt: string) => {
        if (!isOnline) {
            alert("目前處於離線狀態，請連接網路後再試。");
            return;
        }
        if (!supplementalPrompt.trim()) {
            alert("請輸入補充說明。");
            return;
        }

        const isQuickMode = appState.startsWith('QUICK_ANALYSIS');
        const itemToAnalyze = isQuickMode ? quickAnalysisItem : checklist.find(i => i.id === itemId);

        if (!itemToAnalyze || itemToAnalyze.id !== itemId) return;

        // Update item status to loading
        if (isQuickMode) {
            setQuickAnalysisItem(prev => prev ? { ...prev, status: 'loading' } : null);
        } else {
            setChecklist(prev => prev.map(item =>
                item.id === itemId ? { ...item, status: 'loading' } : item
            ));
        }
        
        await runAnalysis(
            itemToAnalyze,
            (_, result) => { // onSuccess
                if (isQuickMode) {
                    setQuickAnalysisItem(prev => prev ? { ...prev, status: 'success', result } : null);
                } else {
                    setChecklist(prev => prev.map(i => i.id === itemId ? { ...i, status: 'success', result } : i));
                }
            },
            (_, errorMsg) => { // onError
                if (isQuickMode) {
                    setQuickAnalysisItem(prev => prev ? { ...prev, status: 'error', error: errorMsg } : null);
                } else {
                    setChecklist(prev => prev.map(i => i.id === itemId ? { ...i, status: 'error', error: errorMsg } : i));
                }
            },
            supplementalPrompt
        );

    }, [isOnline, appState, quickAnalysisItem, checklist, runAnalysis, setQuickAnalysisItem, setChecklist]);

    const itemsToReview = checklist.filter(item => ['loading', 'success', 'error'].includes(item.status));
    const itemsToCapture = checklist.filter(item => ['pending', 'captured'].includes(item.status));

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
                        
                        <div className="upload-section-divider">
                            <span>或者</span>
                        </div>
                        
                        <button onClick={() => setAppState('QUICK_ANALYSIS_CAPTURE')} className="button-secondary full-width">
                            試試單張照片快速分析
                        </button>
                    </section>
                );
            case 'EXTRACTING':
                return <LoadingComponent text="正在從文件中提取巡檢項目..." />;
            case 'CAPTURE':
                const allPhotosTaken = itemsToCapture.every(item => item.status === 'captured');
                const activeItemIndex = itemsToCapture.findIndex(item => item.status === 'pending');
                const currentTask = activeItemIndex !== -1 ? itemsToCapture[activeItemIndex].task : "所有照片已拍攝完畢！";
                return (
                    <section className="capture-section">
                        <h3>步驟 2: 拍攝巡檢照片</h3>
                        <p>下一個項目：<strong>{currentTask}</strong></p>
                        <ul className="checklist">
                            {itemsToCapture.map((item, index) => (
                                <li key={item.id} className={`checklist-item ${index === activeItemIndex ? 'active' : ''} ${item.status === 'captured' ? 'completed' : ''}`}>
                                    <span className="checklist-item-text">{index + 1}. {item.task}</span>
                                    <div className="checklist-item-action">
                                        {item.dataUrl ? (
                                             <img src={item.dataUrl} alt={`預覽 ${item.task}`} />
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
                const analyzedCount = checklist.filter(i => i.status === 'success' || i.status === 'error').length;
                const totalToAnalyze = checklist.filter(i => i.status === 'loading' || i.status === 'success' || i.status === 'error').length;
                return <LoadingComponent text={`正在分析照片... (${analyzedCount} / ${totalToAnalyze})`} />;
            case 'REVIEW':
                 const unconfirmedSuccessCount = itemsToReview.filter(i => i.status === 'success').length;
                return (
                    <section>
                         <h2>步驟 3: 分析與審核結果</h2>
                        <p>您可以在這裡審核並修改 AI 的分析結果，然後點擊「確認記錄」將其存檔。</p>
                        <div className="actions-bar">
                            <button onClick={handleConfirmAll} disabled={unconfirmedSuccessCount === 0}>
                                一鍵記錄所有已完成項目 ({unconfirmedSuccessCount})
                            </button>
                        </div>
                        <div className="inspection-grid" role="list">
                            {itemsToReview.map((item: ChecklistItem) => (
                                <InspectionCard 
                                    key={item.id} 
                                    item={item} 
                                    onConfirm={handleConfirmOne} 
                                    onRetry={(id, e) => handlePhotoRetry(id, e as React.ChangeEvent<HTMLInputElement>)}
                                    onUpdateResult={handleUpdateResult}
                                    onReanalyze={handleReanalyze}
                                />
                            ))}
                        </div>
                    </section>
                );
            case 'QUICK_ANALYSIS_CAPTURE':
                return (
                     <section className="quick-analysis-section">
                        <h2>快速分析模式</h2>
                        <p>請上傳一張照片，或使用相機立即拍攝以進行分析。</p>
                         <div className="actions-bar vertical">
                             <input type="file" id="quick-upload" accept="image/*" onChange={handleQuickPhoto} />
                             <label htmlFor="quick-upload" className="button-primary">從檔案上傳</label>
                             
                             <input type="file" id="quick-capture" accept="image/*" capture="environment" onChange={handleQuickPhoto} />
                             <label htmlFor="quick-capture" className="button-primary">立即拍攝</label>

                             <button onClick={() => setAppState('IDLE')} className="button-secondary">返回主流程</button>
                        </div>
                    </section>
                );
            case 'QUICK_ANALYSIS_ANALYZING':
                return <LoadingComponent text="正在分析您的照片..." />;
            case 'QUICK_ANALYSIS_REVIEW':
                 if (!quickAnalysisItem) return null;
                return (
                    <section>
                        <h2>快速分析結果</h2>
                        <p>您可以在下方審核並修改 AI 的分析結果，或使用手動工具進行測量。</p>
                        <div className="inspection-grid" role="list">
                            <InspectionCard 
                                key={quickAnalysisItem.id} 
                                item={quickAnalysisItem}
                                onRetry={(id, e) => handleQuickPhotoRetry(id, e as React.ChangeEvent<HTMLInputElement>)}
                                onUpdateResult={handleUpdateResult}
                                onSave={handleSaveQuickAnalysis}
                                onReanalyze={handleReanalyze}
                                isQuickMode={true}
                            />
                        </div>
                         <div className="actions-bar">
                            <button onClick={() => { setQuickAnalysisItem(null); setAppState('QUICK_ANALYSIS_CAPTURE'); }} className="button-primary">分析另一張照片</button>
                            <button onClick={() => { setQuickAnalysisItem(null); setAppState('IDLE'); }} className="button-secondary">返回主流程</button>
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
                {(itemsToCapture.length > 0 && appState === 'REVIEW') && (
                     <section className="capture-section">
                        <h3>返回拍攝</h3>
                         <ul className="checklist">
                            {itemsToCapture.map((item, index) => (
                                <li key={item.id} className={`checklist-item ${item.status === 'captured' ? 'completed' : ''}`}>
                                    <span className="checklist-item-text">{index + 1}. {item.task}</span>
                                    <div className="checklist-item-action">
                                        {item.dataUrl ? (
                                             <img src={item.dataUrl} alt={`預覽 ${item.task}`} />
                                        ) : (
                                           '待拍攝'
                                        )}
                                    </div>
                                </li>
                            ))}
                        </ul>
                          <div className="actions-bar">
                            <button onClick={() => setAppState('CAPTURE')} className="button-secondary">
                                返回繼續拍攝
                            </button>
                        </div>
                    </section>
                )}
                <RecordsTable records={confirmedRecords} />
                <ReportSection 
                    records={confirmedRecords}
                    report={report}
                    reportState={reportState}
                    reportError={reportError}
                    onGenerate={handleGenerateReport}
                />
            </main>
            <footer>
                <p>國立勤益科技大學 智慧自動化工程系 劉瑞弘老師研究團隊(drive by Gemini)</p>
            </footer>
             <div className={`status-indicator ${isOnline ? 'online' : 'offline'}`} role="status">
                {isOnline ? '● 線上' : '● 離線'}
            </div>
        </div>
    );
};

const root = ReactDOM.createRoot(document.getElementById('root')!);
root.render(<App />);
